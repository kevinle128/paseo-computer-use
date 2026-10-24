import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  ComputerUseError,
  ComputerUseTransportError,
  HELPER_ERROR_CODES,
} from "../server/computer-use-mcp/contract/errors";
import type { HelperUnsolicitedEvent } from "../server/computer-use-mcp/contract/helper-protocol";
import {
  HELPER_SOURCE_HASH,
  HELPER_SOURCES,
  HelperProcess,
  installMcpShim,
} from "../server/computer-use-mcp/helper";

const FAKE_HELPER_SCRIPT = String.raw`
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin });
const seenCommands = [];
// type_text runs like the real helper: one character every 8 ms, and it
// checks for a cancel between characters.
const typing = new Map();

rl.on("line", (line) => {
  if (!line.trim()) return;
  const req = JSON.parse(line);
  seenCommands.push(req.cmd);

  if (req.cmd === "status") {
    process.stdout.write(JSON.stringify({
      id: req.id,
      ok: true,
      result: {
        osVersion: "macOS 15.0",
        axTrusted: true,
        screenCaptureGranted: true,
        abortTapAvailable: true,
        inputSourceId: "com.apple.keylayout.US",
        isInputMethod: false,
        helperSourceHash: process.env.PASEO_HELPER_SOURCE_HASH ?? "test",
      },
    }) + "\n");
    return;
  }

  if (req.cmd === "end_turn") {
    process.stdout.write(JSON.stringify({
      id: req.id,
      ok: true,
      result: { ok: true },
    }) + "\n");
    return;
  }

  if (req.cmd === "list_apps") {
    process.stdout.write(JSON.stringify({
      id: req.id,
      ok: true,
      result: seenCommands.map((c, idx) => ({
        id: "cmd-" + idx,
        displayName: c,
        isRunning: true,
      })),
    }) + "\n");
    return;
  }

  if (req.cmd === "type_text") {
    const text = req.params.text;
    let typed = 0;
    const timer = setInterval(() => {
      typed += 1;
      if (typed >= text.length) {
        clearInterval(timer);
        typing.delete(req.id);
        process.stdout.write(JSON.stringify({
          id: req.id,
          ok: true,
          result: { ok: true, verification: { state: "verified", reason: "field_value_read_back" } },
        }) + "\n");
      }
    }, 8);
    typing.set(req.id, { timer, typed: () => typed });
    return;
  }

  if (req.cmd === "cancel") {
    const job = typing.get(req.params.requestId);
    if (job) {
      clearInterval(job.timer);
      typing.delete(req.params.requestId);
      seenCommands.push("cancelled-after-" + job.typed());
      process.stdout.write(JSON.stringify({
        id: req.params.requestId,
        ok: false,
        error: { code: "aborted_by_user", message: "The command was cancelled before it finished." },
      }) + "\n");
    }
    process.stdout.write(JSON.stringify({
      id: req.id,
      ok: true,
      result: { cancelled: Boolean(job) },
    }) + "\n");
    return;
  }

  if (req.cmd === "click") {
    if (req.params?.app === "late-app") {
      // Answers after the plugin gave up and ignores the cancel.
      setTimeout(() => {
        process.stdout.write(JSON.stringify({
          id: req.id,
          ok: true,
          result: { ok: true, verification: { state: "verified", reason: "clicked" } },
        }) + "\n");
      }, 150);
      return;
    }
    if (req.params?.app === "slow-app") {
      // Never respond so timeout triggers
      return;
    }
    if (req.params?.app === "abort-escape") {
      process.stdout.write(JSON.stringify({
        event: "abort",
        reason: "escape_key",
      }) + "\n");
      return;
    }
    if (req.params?.app === "abort-shake") {
      process.stdout.write(JSON.stringify({
        event: "abort",
        reason: "user_intervened",
      }) + "\n");
      return;
    }
    if (req.params?.app === "exit-130") {
      process.exit(130);
    }
    if (req.params?.app === "denied-app") {
      process.stdout.write(JSON.stringify({
        id: req.id,
        ok: false,
        error: {
          code: "app_blocked",
          message: "App is denied",
        },
      }) + "\n");
      return;
    }
    process.stdout.write(JSON.stringify({
      id: req.id,
      ok: true,
      result: {
        ok: true,
        verification: { state: "verified", reason: "clicked" },
      },
    }) + "\n");
  }
});
`;

describe("HelperProcess & Helper utilities", () => {
  const activeHelpers: HelperProcess[] = [];
  const tempDirs: string[] = [];

  function createFakeHelper(): HelperProcess {
    const helper = new HelperProcess({
      command: process.execPath,
      args: ["--input-type=module", "-e", FAKE_HELPER_SCRIPT],
      defaultTimeoutMs: 2_000,
    });
    activeHelpers.push(helper);
    return helper;
  }

  afterEach(async () => {
    for (const h of activeHelpers.splice(0)) {
      await h.stop();
    }
    for (const d of tempDirs.splice(0)) {
      rmSync(d, { recursive: true, force: true });
    }
  });

  it("embeds all Swift helper sources and produces a valid source hash", () => {
    expect(HELPER_SOURCE_HASH).toMatch(/^[0-9a-f]{16}$/);
    expect(Object.keys(HELPER_SOURCES)).toEqual(
      expect.arrayContaining([
        "AXEngine.swift",
        "InputDriver.swift",
        "MotionPhysics.swift",
        "ProxyShim.swift",
        "ScreenCapture.swift",
        "VirtualPointerOverlay.swift",
        "main.swift",
      ]),
    );
  });

  it("executes status and click requests over NDJSON and automatically sends end_turn on turn transitions", async () => {
    const helper = createFakeHelper();
    const status = await helper.request("status", {});
    expect(status.axTrusted).toBe(true);
    expect(status.helperSourceHash).toBe(HELPER_SOURCE_HASH);

    const clickRes = await helper.request(
      "click",
      { blockedBundleIds: [], app: "Safari", x: 100, y: 120 },
      { meta: { turnId: "turn-1" } },
    );
    expect(clickRes.ok).toBe(true);

    // Transitioning from turn-1 to turn-2 should automatically emit an end_turn before list_apps
    const apps = await helper.request("list_apps", { blockedBundleIds: [] }, { meta: { turnId: "turn-2" } });
    expect(apps.map((a) => a.displayName)).toEqual(["status", "click", "end_turn", "list_apps"]);
  });

  it("maps helper error responses to ComputerUseError", async () => {
    const helper = createFakeHelper();
    await expect(
      helper.request("click", { blockedBundleIds: [], app: "denied-app", x: 10, y: 10 }),
    ).rejects.toMatchObject({
      name: "ComputerUseError",
      code: "app_blocked",
    });
  });

  it("rejects timed-out requests with ComputerUseTransportError", async () => {
    const helper = createFakeHelper();
    await expect(
      helper.request("click", { blockedBundleIds: [], app: "slow-app", x: 10, y: 10 }, { timeoutMs: 80 }),
    ).rejects.toBeInstanceOf(ComputerUseTransportError);
  });

  it("handles unsolicited abort events for escape_key and user_intervened", async () => {
    const helper = createFakeHelper();
    const events: HelperUnsolicitedEvent[] = [];
    helper.onEvent((ev) => events.push(ev));

    await expect(
      helper.request("click", { blockedBundleIds: [], app: "abort-escape", x: 10, y: 10 }),
    ).rejects.toMatchObject({
      name: "ComputerUseError",
      code: "aborted_by_user",
    });

    await expect(
      helper.request("click", { blockedBundleIds: [], app: "abort-shake", x: 10, y: 10 }),
    ).rejects.toMatchObject({
      name: "ComputerUseError",
      code: "user_intervened",
    });

    expect(events).toEqual([
      expect.objectContaining({ event: "abort", reason: "escape_key" }),
      expect.objectContaining({ event: "abort", reason: "user_intervened" }),
    ]);
  });

  it("maps process exit code 130 to userStoppedSession and emits an escape_key abort event", async () => {
    const helper = createFakeHelper();
    const events: HelperUnsolicitedEvent[] = [];
    helper.onEvent((ev) => events.push(ev));

    let caught: unknown;
    try {
      await helper.request("click", { blockedBundleIds: [], app: "exit-130", x: 10, y: 10 });
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ComputerUseError);
    expect((caught as ComputerUseError).code).toBe("aborted_by_user");
    expect(events).toEqual([
      expect.objectContaining({ event: "exited", code: 130 }),
      expect.objectContaining({ event: "abort", reason: "escape_key" }),
    ]);
  });

  it("cancels a long type_text in the helper within one second of an abort", async () => {
    const helper = createFakeHelper();
    const controller = new AbortController();
    const longText = "x".repeat(1_000); // about 8 s of typing

    const started = performance.now();
    const typing = helper.request(
      "type_text",
      { blockedBundleIds: [], app: "TextEdit", text: longText },
      { signal: controller.signal, timeoutMs: 30_000 },
    );
    setTimeout(() => controller.abort(), 50);

    await expect(typing).rejects.toMatchObject({ code: "aborted_by_user" });
    expect(performance.now() - started).toBeLessThan(1_000);

    // The helper got the cancel and stopped typing well before the end.
    await expect
      .poll(async () => (await helper.request("list_apps", { blockedBundleIds: [] })).map((a) => a.displayName), { timeout: 1_000 })
      .toContainEqual(expect.stringMatching(/^cancelled-after-\d+$/));
    const seen = (await helper.request("list_apps", { blockedBundleIds: [] })).map((a) => a.displayName);
    expect(seen).toContain("cancel");
    const stoppedAt = Number(seen.find((name) => name.startsWith("cancelled-after-"))?.split("-").pop());
    expect(stoppedAt).toBeLessThan(longText.length);
  });

  it("cancels a timed-out command in the helper", async () => {
    const helper = createFakeHelper();
    await expect(
      helper.request("type_text", { blockedBundleIds: [], app: "TextEdit", text: "y".repeat(1_000) }, { timeoutMs: 100 }),
    ).rejects.toBeInstanceOf(ComputerUseTransportError);
    await expect
      .poll(async () => (await helper.request("list_apps", { blockedBundleIds: [] })).map((a) => a.displayName), { timeout: 1_000 })
      .toContainEqual(expect.stringMatching(/^cancelled-after-\d+$/));
  });

  it("logs a response that arrives after the request timed out", async () => {
    const helper = createFakeHelper();
    const events: HelperUnsolicitedEvent[] = [];
    helper.onEvent((ev) => events.push(ev));

    await expect(
      helper.request("click", { blockedBundleIds: [], app: "late-app", x: 1, y: 1 }, { timeoutMs: 50 }),
    ).rejects.toBeInstanceOf(ComputerUseTransportError);

    await expect
      .poll(() => events.filter((ev) => ev.event === "log").map((ev) => ev.message), { timeout: 1_000 })
      .toContainEqual(expect.stringMatching(/Late helper response for 'click'/));
  });

  it("emits an exited event when the helper process ends", async () => {
    const helper = createFakeHelper();
    const events: HelperUnsolicitedEvent[] = [];
    helper.onEvent((ev) => events.push(ev));
    await helper.request("status", {});
    await helper.stop();
    expect(events).toContainEqual(expect.objectContaining({ event: "exited" }));
  });

  it("installs the MCP shim atomically into <stateDir>/bin/paseo-computer-use-mcp", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "paseo-cu-shim-"));
    tempDirs.push(dir);

    const installed = installMcpShim({
      stateDir: dir,
      socketPath: path.join(dir, "plugin.sock"),
    });
    expect(installed.mode).toBe("node-fallback");
    expect(installed.shimPath).toBe(path.join(dir, "bin", "paseo-computer-use-mcp"));
  });
});

describe("helper error codes", () => {
  it("match the code strings declared by the Swift HelperError", () => {
    const source = HELPER_SOURCES["AXEngine.swift"];
    expect(source).toBeDefined();
    const swiftCodes = [...source.matchAll(/public static let \w+ = "([a-z_]+)"/g)].map((m) => m[1]);
    expect(swiftCodes.length).toBeGreaterThan(0);
    expect([...swiftCodes].sort()).toEqual([...HELPER_ERROR_CODES].sort());
  });
});
