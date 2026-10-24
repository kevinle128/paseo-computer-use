import { createPaseoClient } from "@getpaseo/client";
import type { PluginServerContext } from "@getpaseo/plugin/server";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { computeHomeKey, computeLegacyHomeKey, migrateLegacyIdentityMap } from "../index.server";
import { createComputerUseService } from "../server/computer-use-mcp";
import { installMcpShim, shellQuote } from "../server/computer-use-mcp/helper/install-shim";
import { ComputerUseSocketListener, isSocketLive } from "../server/computer-use-mcp/mcp/socket-listener";
import { registerComputerUseRpcHandlers } from "../server/paseo/rpc-handlers";
import { statusGetRpc, statusOutputSchema } from "../shared/rpc";
import { computerUseSettingsSchema, parseBundleIdList, toggleProvider } from "../shared/settings";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";

let scratch: string;

beforeEach(() => {
  // A short root keeps socket paths under the 104-byte macOS limit.
  scratch = mkdtempSync(path.join("/tmp", "cu-"));
});

afterEach(() => {
  rmSync(scratch, { recursive: true, force: true });
});

describe("computeHomeKey", () => {
  it("gives the default home one key however it is spelled", () => {
    const home = realpathSync(scratch);
    const unset = computeHomeKey({}, home);
    expect(computeHomeKey({ PASEO_HOME: "~/.paseo" }, home)).toBe(unset);
    expect(computeHomeKey({ PASEO_HOME: path.join(home, ".paseo") }, home)).toBe(unset);
    expect(computeHomeKey({ PASEO_HOME: `${path.join(home, ".paseo")}/` }, home)).toBe(unset);
  });

  it("does not depend on the listen address", () => {
    const home = realpathSync(scratch);
    expect(computeHomeKey({ PASEO_LISTEN: "127.0.0.1:7777" }, home)).toBe(computeHomeKey({}, home));
  });

  it("gives a symlink to a home the same key as the home itself", () => {
    const home = realpathSync(scratch);
    const real = path.join(home, "real-home");
    mkdirSync(real);
    const link = path.join(home, "link-home");
    symlinkSync(real, link);
    expect(computeHomeKey({ PASEO_HOME: link }, home)).toBe(computeHomeKey({ PASEO_HOME: real }, home));
  });

  it("gives different homes different keys", () => {
    const home = realpathSync(scratch);
    expect(computeHomeKey({ PASEO_HOME: path.join(home, "a") }, home)).not.toBe(
      computeHomeKey({ PASEO_HOME: path.join(home, "b") }, home),
    );
  });
});

describe("migrateLegacyIdentityMap", () => {
  const map = JSON.stringify({ c1: { clientId: "c1", agentId: "a1", updatedAt: "t" } });

  it("copies the map from the earlier state dir once", () => {
    const legacyKey = computeLegacyHomeKey({});
    const legacyDir = path.join(scratch, legacyKey);
    const stateDir = path.join(scratch, "newkey");
    mkdirSync(legacyDir);
    mkdirSync(stateDir);
    writeFileSync(path.join(legacyDir, "client-bindings.json"), map);

    expect(migrateLegacyIdentityMap(scratch, stateDir, legacyKey)).toBe(true);
    expect(readFileSync(path.join(stateDir, "client-bindings.json"), "utf8")).toBe(map);

    // A second start keeps the bindings made since the copy.
    writeFileSync(path.join(stateDir, "client-bindings.json"), "{}");
    expect(migrateLegacyIdentityMap(scratch, stateDir, legacyKey)).toBe(false);
    expect(readFileSync(path.join(stateDir, "client-bindings.json"), "utf8")).toBe("{}");
  });

  it("does nothing when there is no earlier map or the key did not change", () => {
    const stateDir = path.join(scratch, "same");
    mkdirSync(stateDir);
    expect(migrateLegacyIdentityMap(scratch, stateDir, "missing")).toBe(false);
    writeFileSync(path.join(stateDir, "client-bindings.json"), map);
    expect(migrateLegacyIdentityMap(scratch, stateDir, "same")).toBe(false);
  });
});

function createListener(socketPath: string): ComputerUseSocketListener {
  return new ComputerUseSocketListener({
    socketPath,
    createServerForClient: () => {
      throw new Error("no client is expected in this test");
    },
  });
}

describe("socket listener start", () => {
  it("refuses to take over a socket that another listener serves", async () => {
    const socketPath = path.join(scratch, "mcp.sock");
    const first = createListener(socketPath);
    await first.start();
    try {
      const second = createListener(socketPath);
      await expect(second.start()).rejects.toThrow(/already serving computer use/);
      // Stopping the refused listener must not remove the socket it never
      // created; the first listener keeps serving.
      await second.stop();
      expect(await isSocketLive(socketPath)).toBe(true);
    } finally {
      await first.stop();
    }
  });

  it("replaces a stale socket file that nothing listens on", async () => {
    const socketPath = path.join(scratch, "mcp.sock");
    writeFileSync(socketPath, "");
    expect(await isSocketLive(socketPath)).toBe(false);

    const listener = createListener(socketPath);
    await listener.start();
    try {
      expect(await isSocketLive(socketPath)).toBe(true);
    } finally {
      await listener.stop();
    }
  });
});

describe("shim wrapper quoting", () => {
  const awkward = "/tmp/a b/it's $HOME `id` \"q\"";

  it("passes an awkward path to the program as one unchanged argument", () => {
    const printed = execFileSync("sh", ["-c", `set -- ${shellQuote(awkward)}; printf '%s|%s' "$#" "$1"`], {
      encoding: "utf8",
    });
    expect(printed).toBe(`1|${awkward}`);
  });

  it("writes a wrapper whose socket argument survives the shell", () => {
    const stateDir = path.join(scratch, "state dir");
    const socketPath = path.join(scratch, "it's $x.sock");
    const { shimPath } = installMcpShim({ stateDir, socketPath });
    const script = readFileSync(shimPath, "utf8");
    expect(script).toContain(`--socket ${shellQuote(socketPath)}`);

    // Replace the exec target with printf so the script shows the argv it
    // would pass, without starting Node.
    const execLine = script.split("\n").find((line) => line.includes("exec "));
    expect(execLine).toBeDefined();
    const args = (execLine ?? "").replace(/^.*?exec \S+ /, "");
    const printed = execFileSync("sh", ["-c", `printf '%s\\n' ${args}`, "shim", "--client", "c1"], {
      encoding: "utf8",
    });
    expect(printed.trim().split("\n")).toEqual([
      path.join(stateDir, "bin", "paseo-computer-use-shim.mjs"),
      "--socket",
      socketPath,
      "--client",
      "c1",
    ]);
  });
});

describe("settings helpers", () => {
  it("adds and removes one provider and keeps ids the screen does not list", () => {
    expect(toggleProvider(["claude", "codex", "omp"], "codex", false)).toEqual(["claude", "omp"]);
    expect(toggleProvider(["claude", "future"], "omp", true)).toEqual(["claude", "future", "omp"]);
    expect(toggleProvider(["claude"], "claude", true)).toEqual(["claude"]);
  });

  it("reads bundle ids from commas and new lines and drops blanks and repeats", () => {
    expect(parseBundleIdList(" com.a.App,\ncom.b.App\n\n, com.a.App ")).toEqual(["com.a.App", "com.b.App"]);
    expect(parseBundleIdList("")).toEqual([]);
  });

  it("defaults to the three supported providers", () => {
    expect(computerUseSettingsSchema.parse({}).injectProviders).toEqual(["claude", "codex", "omp"]);
  });
});

// The status RPC never reaches the helper when the build is not ready, so a
// port that fails every request is enough.
const unusedHelperPort: HelperPort = {
  request: () => Promise.reject(new Error("the helper is not used in this test")),
  onEvent: () => () => {},
  stop: async () => {},
};

describe("status RPC", () => {
  it("returns a value that matches the shared status schema, with the socket error", async () => {
    const handlers = new Map<string, (input: unknown) => Promise<unknown>>();
    const handlerContext = { paseo: createPaseoClient({ url: "ws://127.0.0.1:1" }) };
    const server: PluginServerContext = {
      registerSettings: () => {
        throw new Error("not used");
      },
      handle: (contract, handler) => {
        handlers.set(contract.name, async (raw) => handler(contract.input.parse(raw), handlerContext));
      },
      registerProvider: () => {},
      registerUsageSource: () => {},
      on: () => () => {},
      before: () => () => {},
    };
    const service = createComputerUseService({
      helperPort: unusedHelperPort,
      platformSupported: true,
      getHelperBuildStatus: () => ({ state: "failed", error: "swiftc missing" }),
    });
    registerComputerUseRpcHandlers(server, service, { getSocketError: () => "socket in use" });

    const handler = handlers.get(statusGetRpc.name);
    expect(handler).toBeDefined();
    const output = statusOutputSchema.parse(await handler?.({}));
    expect(output).toMatchObject({
      helperBuildState: "failed",
      helperBuildError: "swiftc missing",
      axTrusted: false,
      screenCaptureGranted: false,
      socketError: "socket in use",
    });
    await service.stop();
  });
});
