import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ComputerUseError } from "../server/computer-use-mcp/contract/errors";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";
import type { RawAXTree } from "../server/computer-use-mcp/contract/results";
import type {
  HelperCommandName,
  HelperCommands,
} from "../server/computer-use-mcp/contract/helper-protocol";
import { type ComputerUseService, createComputerUseService } from "../server/computer-use-mcp";
import { MUTATING_TOOL_NAMES, READ_TOOL_NAMES } from "../server/computer-use-mcp/mcp/tools";
import { USE_BROWSER_TOOLS_MESSAGE } from "../server/computer-use-mcp/policy";
import type { ActionSettlerClock } from "../server/computer-use-mcp/runtime/action-settler";
import { ClientIdentityStore } from "../server/paseo/identity-store";
import { UnixSocketTransport } from "./unix-socket-transport";

type RequestOptions = Parameters<HelperPort["request"]>[2];
type Handlers = {
  [K in HelperCommandName]: (
    params: HelperCommands[K]["params"],
    options: RequestOptions,
  ) => HelperCommands[K]["result"] | Promise<HelperCommands[K]["result"]>;
};

// Replies copy the shape the Swift helper produces: a header-only text line
// next to the raw tree, whose ids are "<pid>:<child path>" and whose nodes
// carry AX roles, states, and actions; action results carry a verification.
const TEXTEDIT_TREE = {
  window_id: 42,
  root: {
    native_id: "4242:",
    role: "AXApplication",
    name: "TextEdit",
    children: [
      {
        native_id: "4242:0",
        role: "AXWindow",
        name: "Untitled",
        bounds: { x: 0, y: 25, width: 800, height: 600 },
        states: ["enabled"],
        actions: ["AXRaise"],
        children: [
          {
            native_id: "4242:0.0",
            role: "AXButton",
            name: "Bold",
            bounds: { x: 10, y: 30, width: 40, height: 20 },
            states: ["enabled"],
            actions: ["AXPress"],
          },
          {
            native_id: "4242:0.1",
            role: "AXTextArea",
            value: "hello",
            bounds: { x: 10, y: 60, width: 780, height: 540 },
            states: ["enabled", "focused"],
          },
          {
            native_id: "4242:0.2",
            role: "AXButton",
            name: "Italic",
            bounds: { x: 60, y: 30, width: 40, height: 20 },
            states: ["enabled"],
            actions: ["AXPress"],
          },
          {
            native_id: "4242:0.3",
            role: "AXButton",
            name: "Underline",
            bounds: { x: 110, y: 30, width: 40, height: 20 },
            states: ["enabled"],
            actions: ["AXPress"],
          },
        ],
      },
    ],
  },
  focused_element: "4242:0.1",
};

function createFakeHelper(overrides: Partial<Handlers> = {}) {
  const calls: Array<{ cmd: HelperCommandName; params: unknown; signal?: AbortSignal }> = [];
  const verified = { ok: true as const, verification: { state: "verified" as const, reason: "value_read_back" } };
  const handlers: Handlers = {
    status: () => ({
      osVersion: "15.6.0",
      axTrusted: true,
      screenCaptureGranted: true,
      abortTapAvailable: true,
      inputSourceId: "com.apple.keylayout.ABC",
      isInputMethod: false,
      helperSourceHash: "test",
    }),
    list_apps: () => [
      { id: "com.apple.TextEdit", bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", isRunning: true },
    ],
    list_windows: () => [
      { id: 42, app: "TextEdit", bundleIdentifier: "com.apple.TextEdit", title: "Untitled", bounds: { x: 0, y: 25, width: 800, height: 600 } },
    ],
    get_app_state: () => ({
      app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
      windowState: {
        text: "App: TextEdit (pid: 4242, window: 42) bounds=(0,25,800x600)",
        rawTree: TEXTEDIT_TREE,
        screenshot: null,
      },
    }),
    "capture.signature": () => ({
      signature: Buffer.alloc(64 * 40, 128).toString("base64"),
      width: 64,
      height: 40,
      windowId: 42,
      windowWidth: 800,
      windowHeight: 600,
    }),
    click: () => verified,
    drag: () => verified,
    scroll: () => verified,
    press_key: () => verified,
    type_text: () => verified,
    paste_text: () => verified,
    set_value: () => verified,
    select_text: () => verified,
    perform_secondary_action: () => verified,
    end_turn: () => ({ ok: true }),
    cancel: () => ({ cancelled: false }),
    "abort_tap.arm": () => ({ armed: true }),
    "abort_tap.disarm": () => ({ armed: false }),
    ...overrides,
  };
  const helperPort: HelperPort = {
    async request<K extends HelperCommandName>(
      cmd: K,
      params: HelperCommands[K]["params"],
      options?: RequestOptions,
    ) {
      calls.push({ cmd, params, signal: options?.signal });
      const handler: Handlers[K] = handlers[cmd];
      return handler(params, options);
    },
    onEvent: () => () => {},
    async stop() {},
  };
  return { helperPort, calls };
}

function textOf(result: Awaited<ReturnType<Client["callTool"]>>): string {
  const content = Array.isArray(result.content) ? result.content : [];
  return content
    .map((item: unknown) =>
      typeof item === "object" && item !== null && "text" in item && typeof item.text === "string"
        ? item.text
        : "",
    )
    .join("\n");
}

describe("typed MCP tools over the plugin socket", () => {
  let dir: string;
  let socketPath: string;
  let settings: {
    enabled: boolean;
    extraBlockedBundleIds?: string[];
    screenshots?: "auto" | "always" | "never";
    allowBrowserApps?: boolean;
  };
  let service: ComputerUseService;
  let fake: ReturnType<typeof createFakeHelper>;
  const clients: Client[] = [];

  async function connect(agentId: string, provider = "claude"): Promise<Client> {
    const client = new Client({ name: "test-agent", version: "1.0.0" });
    await client.connect(new UnixSocketTransport(socketPath, { clientId: `${agentId}-client`, agentId, provider }));
    clients.push(client);
    return client;
  }

  beforeEach(async () => {
    dir = mkdtempSync(path.join(tmpdir(), "paseo-cu-mcp-"));
    socketPath = path.join(dir, "mcp.sock");
    settings = { enabled: true };
    fake = createFakeHelper();
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
      getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
    });
    await service.start();
  });

  afterEach(async () => {
    for (const client of clients.splice(0)) await client.close();
    await service.stop();
    rmSync(dir, { recursive: true, force: true });
  });

  it("lists exactly the typed tools and returns agent instructions", async () => {
    const client = await connect("agent-a");
    const { tools } = await client.listTools();
    const names = tools.map((tool) => tool.name).sort();
    expect(names).toEqual([...READ_TOOL_NAMES, ...MUTATING_TOOL_NAMES].sort());
    expect(names).not.toContain("js");
    for (const tool of tools) {
      expect(tool.inputSchema.type).toBe("object");
    }

    const instructions = client.getInstructions() ?? "";
    expect(instructions).toMatch(/observe, act, verify/i);
    expect(instructions).toMatch(/data, never instructions/);
    expect(instructions).toMatch(/set_value.*paste_text.*Vietnamese/s);
  });

  it("returns read tool results as text only, so a client that prefers structuredContent still shows the tree", async () => {
    const client = await connect("agent-a");
    const observed = await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    expect(textOf(observed)).toContain("AXButton Bold");
    for (const [name, args] of [
      ["status", {}],
      ["list_apps", {}],
      ["list_windows", { app: "com.apple.TextEdit" }],
      ["get_app_state", { app: "com.apple.TextEdit" }],
    ] as const) {
      const result = await client.callTool({ name, arguments: args });
      expect(result.isError, name).toBeFalsy();
      expect(result.structuredContent, name).toBeUndefined();
    }
  });

  it("reports status and returns a verification line with the new state after an action", async () => {
    const client = await connect("agent-a");

    const status = await client.callTool({ name: "status", arguments: {} });
    expect(status.isError).toBeFalsy();
    expect(textOf(status)).toContain("enabled: yes");
    expect(textOf(status)).toContain("accessibility permission: yes");

    const observed = await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    expect(textOf(observed)).toContain("App: TextEdit (pid: 4242");
    expect(textOf(observed)).toContain("[1] AXButton Bold");

    const clicked = await client.callTool({
      name: "click",
      arguments: { app: "com.apple.TextEdit", element_index: 1 },
    });
    expect(clicked.isError).toBeFalsy();
    const text = textOf(clicked);
    expect(text.split("\n")[0]).toBe("verified");
    expect(text).not.toMatch(/success/i);
    // Claude Code shows structuredContent instead of the text, so a success
    // result must not carry one or the agent loses the tree.
    expect(clicked.structuredContent).toBeUndefined();
    expect(fake.calls.filter((call) => call.cmd === "click")).toHaveLength(1);
    // The new state is read back after the action.
    expect(fake.calls.at(-1)?.cmd).toBe("get_app_state");
  });

  it("reports an unverified action as unverified, never as success", async () => {
    fake = createFakeHelper({
      type_text: () => ({ ok: true, verification: { state: "unverified", reason: "value did not change" } }),
    });
    await service.stop();
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
      getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
    });
    await service.start();
    const client = await connect("agent-a");

    const typed = await client.callTool({
      name: "type_text",
      arguments: { app: "com.apple.TextEdit", text: "xin chao" },
    });
    expect(textOf(typed).split("\n")[0]).toBe("unverified: value did not change");
    expect(textOf(typed)).not.toMatch(/success/i);
  });

  async function restartWith(overrides: Partial<Handlers>, options: { waitClock?: ActionSettlerClock } = {}): Promise<void> {
    await service.stop();
    fake = createFakeHelper(overrides);
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
      ...options,
      getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
    });
    await service.start();
  }

  function callsOf(cmd: HelperCommandName): unknown[] {
    return fake.calls.filter((call) => call.cmd === cmd).map((call) => call.params);
  }

  it("sends the native id of the element the agent named, never an index", async () => {
    const client = await connect("agent-a");
    // The display name resolves through the bundle id the helper reported.
    const observed = await client.callTool({ name: "get_app_state", arguments: { app: "TextEdit" } });
    const lines = textOf(observed).split("\n");
    expect(lines).toContain("    [1] AXButton Bold [10..50, 30..50]");
    expect(lines.some((line) => line.includes("[2] AXTextArea"))).toBe(true);

    await client.callTool({ name: "click", arguments: { app: "TextEdit", element_index: 1 } });
    expect(callsOf("click")).toEqual([
      {
        app: "TextEdit",
        blockedBundleIds: expect.arrayContaining(["com.apple.Passwords", "com.bitwarden.desktop"]),
        blockedBundleIdPrefixes: expect.any(Array),
        overlayLabel: "Claude",
        windowId: 42,
        nativeId: "4242:0.0",
        expected: { role: "AXButton", name: "Bold", frame: { x: 10, y: 30, width: 40, height: 20 } },
      },
    ]);

    await client.callTool({ name: "set_value", arguments: { app: "TextEdit", element_index: 2, value: "hi" } });
    expect(callsOf("set_value")).toEqual([
      {
        app: "TextEdit",
        blockedBundleIds: expect.arrayContaining(["com.apple.Passwords"]),
        blockedBundleIdPrefixes: expect.any(Array),
        windowId: 42,
        nativeId: "4242:0.1",
        expected: { role: "AXTextArea", frame: { x: 10, y: 60, width: 780, height: 540 } },
        value: "hi",
      },
    ]);
  });

  it("sends the native id of the element named for paste_text, and none without one", async () => {
    const client = await connect("agent-a");
    await client.callTool({ name: "get_app_state", arguments: { app: "TextEdit" } });
    await client.callTool({ name: "paste_text", arguments: { app: "TextEdit", element_index: 2, text: "hi" } });
    await client.callTool({ name: "paste_text", arguments: { app: "TextEdit", text: "again", window_id: 42 } });
    expect(callsOf("paste_text")).toEqual([
      expect.objectContaining({
        windowId: 42,
        nativeId: "4242:0.1",
        expected: { role: "AXTextArea", frame: { x: 10, y: 60, width: 780, height: 540 } },
        text: "hi",
      }),
      expect.objectContaining({ windowId: 42, text: "again" }),
    ]);
    expect(callsOf("paste_text")[1]).not.toHaveProperty("nativeId");
  });

  it("asks the helper for the raw tree only and diffs the condensed text itself", async () => {
    const client = await connect("agent-a");
    await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    const again = await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    expect(textOf(again)).toBe("No accessibility changes.");
    const full = await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit", full: true } });
    expect(textOf(full)).toContain("[1] AXButton Bold");
    for (const params of callsOf("get_app_state")) {
      expect(params).toMatchObject({ app: "com.apple.TextEdit" });
      expect(params).not.toHaveProperty("disableDiff");
      expect(params).not.toHaveProperty("query");
    }
  });

  it("returns stale_element without calling the helper for an unknown index or another app", async () => {
    const client = await connect("agent-a");
    const before = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", element_index: 1 } });
    expect(before.structuredContent).toMatchObject({ error: { code: "stale_element" } });

    await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    const unknownIndex = await client.callTool({
      name: "click",
      arguments: { app: "com.apple.TextEdit", element_index: 99 },
    });
    expect(unknownIndex.structuredContent).toMatchObject({ error: { code: "stale_element" } });

    const otherApp = await client.callTool({
      name: "click",
      arguments: { app: "com.apple.Notes", element_index: 1 },
    });
    expect(otherApp.structuredContent).toMatchObject({ error: { code: "stale_element" } });
    expect(callsOf("click")).toHaveLength(0);
  });

  it("maps the helper's stale code to stale_element and other AX failures to action_failed", async () => {
    await restartWith({
      click: () => {
        throw new ComputerUseError({
          code: "stale_element",
          message: "Element '4242:0.0' changed since the latest snapshot; call get_app_state again.",
        });
      },
      set_value: () => {
        throw new ComputerUseError({
          code: "accessibility_error",
          message: "AXUIElementSetAttributeValue failed with error -25200.",
        });
      },
    });
    const client = await connect("agent-a");
    await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });

    const stale = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", element_index: 1 } });
    expect(stale.isError).toBe(true);
    expect(stale.structuredContent).toMatchObject({ error: { code: "stale_element" } });

    const failed = await client.callTool({
      name: "set_value",
      arguments: { app: "com.apple.TextEdit", element_index: 2, value: "x" },
    });
    expect(failed.structuredContent).toMatchObject({ error: { code: "action_failed" } });
  });

  it("reports a posted click that the helper could not check as unverified", async () => {
    await restartWith({
      click: () => ({
        ok: true,
        verification: { state: "unverified", reason: "events posted; effect not checked" },
      }),
    });
    const client = await connect("agent-a");
    const clicked = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
    expect(clicked.isError).toBeFalsy();
    expect(textOf(clicked).split("\n")[0]).toBe("unverified: events posted; effect not checked");
    expect(clicked.structuredContent).toBeUndefined();
  });

  it("refuses actions with computer_use_disabled after the setting is turned off", async () => {
    const client = await connect("agent-a");
    settings.enabled = false;

    const refused = await client.callTool({
      name: "click",
      arguments: { app: "com.apple.TextEdit", x: 10, y: 10 },
    });
    expect(refused.isError).toBe(true);
    expect(textOf(refused)).toMatch(/^error: computer_use_disabled/);
    expect(refused.structuredContent).toMatchObject({ error: { code: "computer_use_disabled" } });
    expect(fake.calls.some((call) => call.cmd === "click")).toBe(false);

    // status still answers, so the agent can learn why.
    const status = await client.callTool({ name: "status", arguments: {} });
    expect(textOf(status)).toContain("enabled: no");
  });

  it("returns computer_busy to a second agent and app_blocked for password managers", async () => {
    const owner = await connect("agent-owner");
    const other = await connect("agent-other");

    await owner.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    const busy = await other.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    expect(busy.structuredContent).toMatchObject({ error: { code: "computer_busy" } });

    const blocked = await owner.callTool({ name: "get_app_state", arguments: { app: "com.1password.1password" } });
    expect(blocked.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
  });

  it("refuses a blocked bundle id, even when it is not running, without calling the helper", async () => {
    const client = await connect("agent-a");
    for (const app of [
      "com.apple.Passwords",
      "me.proton.pass.electron",
      "Keychain Access",
      "com.agilebits.onepassword7",
      "1Password 7",
      "com.apple.SecurityAgent",
      "SecurityAgent",
    ]) {
      const blocked = await client.callTool({ name: "get_app_state", arguments: { app } });
      expect(blocked.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
    }
    expect(fake.calls).toEqual([]);
  });

  it("refuses the user's extra blocked bundle ids without calling the helper, and sends them to it", async () => {
    settings = { enabled: true, extraBlockedBundleIds: ["com.example.Vault"] };
    const client = await connect("agent-a");

    const blocked = await client.callTool({ name: "click", arguments: { app: "com.example.vault", x: 1, y: 1 } });
    expect(blocked.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
    expect(fake.calls).toEqual([]);

    await client.callTool({ name: "get_app_state", arguments: { app: "TextEdit" } });
    expect(callsOf("get_app_state")).toEqual([
      expect.objectContaining({ blockedBundleIds: expect.arrayContaining(["com.example.Vault", "com.1password.1password"]) }),
    ]);
  });

  it("returns app_blocked when the helper resolves a name to a blocked bundle id", async () => {
    // The fake resolves the name the way the Swift helper does and refuses it
    // before reading the tree, with the helper's appNotAllowed code.
    const readTree = (params: HelperCommands["get_app_state"]["params"]) => {
      if (params.app === "Vault" && params.blockedBundleIds.includes("com.bitwarden.desktop")) {
        throw new ComputerUseError({ code: "app_blocked", message: "Computer Use is not allowed to use the app 'com.bitwarden.desktop' for safety reasons." });
      }
      return createFakeHelper().helperPort.request("get_app_state", params);
    };
    await restartWith({ get_app_state: readTree });
    const client = await connect("agent-a");

    const blocked = await client.callTool({ name: "get_app_state", arguments: { app: "Vault" } });
    expect(blocked.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
  });

  describe("web browsers", () => {
    // Valid arguments for every tool that reads or acts in one app, with the
    // helper command each one sends.
    const appTools = (app: string) =>
      [
        ["get_app_state", { app }, "get_app_state"],
        ["wait_for", { app, any: [{ name: "bold", appears: { role: "AXButton", name: "bold" } }] }, "get_app_state"],
        ["click", { app, x: 10, y: 10 }, "click"],
        ["drag", { app, from_x: 1, from_y: 1, to_x: 5, to_y: 5 }, "drag"],
        ["scroll", { app, direction: "down", x: 10, y: 10 }, "scroll"],
        ["press_key", { app, key: "Command+w" }, "press_key"],
        ["type_text", { app, text: "hi" }, "type_text"],
        ["paste_text", { app, text: "hi" }, "paste_text"],
        ["set_value", { app, element_index: 2, value: "hi" }, "set_value"],
        ["select_text", { app, element_index: 2, text: "hi" }, "select_text"],
        ["secondary_action", { app, element_index: 1, action: "AXShowMenu" }, "perform_secondary_action"],
      ] as const;

    // A helper that reports the app it was asked for, so a browser read gives
    // element indexes for that browser.
    const readAnyApp = (params: HelperCommands["get_app_state"]["params"]) => ({
      app: { bundleIdentifier: params.app, displayName: params.app },
      windowState: { text: "App: Browser (pid: 4242, window: 42)", rawTree: TEXTEDIT_TREE, screenshot: null },
    });

    it("refuses every app tool for a browser with use_browser_tools before any helper call", async () => {
      const client = await connect("agent-a");
      for (const app of ["com.google.Chrome", "com.apple.Safari", "Google Chrome", "safari"]) {
        for (const [name, args] of appTools(app)) {
          const refused = await client.callTool({ name, arguments: args });
          expect(refused.isError, `${name} ${app}`).toBe(true);
          expect(refused.structuredContent, `${name} ${app}`).toEqual({
            error: { code: "use_browser_tools", message: USE_BROWSER_TOOLS_MESSAGE },
          });
          expect(textOf(refused)).toContain("browser_navigate");
          expect(textOf(refused)).toContain(
            "If these tools are not available, ask the user to turn on browser tools in Paseo settings, or to allow web browsers in Computer Use settings.",
          );
        }
      }
      // No read, no key press: the Command+w close button fallback never runs.
      expect(fake.calls).toEqual([]);
      expect((await service.getStatus()).activeOwner).toBeNull();
    });

    it("leaves the list tools alone and keeps browsers in their lists", async () => {
      const client = await connect("agent-a");
      for (const [name, args] of [
        ["list_apps", {}],
        ["list_windows", { app: "com.google.Chrome" }],
        ["status", {}],
      ] as const) {
        const result = await client.callTool({ name, arguments: args });
        expect(result.isError, name).toBeFalsy();
      }
      for (const params of [...callsOf("list_apps"), ...callsOf("list_windows")]) {
        expect((params as { blockedBundleIds: string[] }).blockedBundleIds).not.toContain("com.google.Chrome");
      }
    });

    it("sends the browsers with every app command, so a partial name the helper resolves to one is refused", async () => {
      const refuseChrome = (params: { app: string; blockedBundleIds: string[] }) => {
        if (params.app === "chrome" && params.blockedBundleIds.includes("com.google.Chrome")) {
          throw new ComputerUseError({
            code: "app_blocked",
            message: "Computer Use is not allowed to use the app 'com.google.Chrome' for safety reasons.",
            bundleId: "com.google.Chrome",
          });
        }
      };
      await restartWith(
        {
          get_app_state: (params) => {
            refuseChrome(params);
            return createFakeHelper().helperPort.request("get_app_state", params);
          },
          press_key: (params) => {
            refuseChrome(params);
            return { ok: true, verification: { state: "verified" } };
          },
        },
        { waitClock: { now: () => 0, sleep: async () => {} } },
      );
      const client = await connect("agent-a");

      for (const [name, args] of [
        ["get_app_state", { app: "chrome" }],
        ["press_key", { app: "chrome", key: "Command+t" }],
        ["wait_for", { app: "chrome", any: [{ name: "bold", appears: { role: "AXButton", name: "bold" } }] }],
      ] as const) {
        const refused = await client.callTool({ name, arguments: args });
        expect(refused.structuredContent, name).toEqual({
          error: { code: "use_browser_tools", message: USE_BROWSER_TOOLS_MESSAGE },
        });
      }

      // A native app is read and acted in as before; its commands carry the
      // browsers too.
      const read = await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
      expect(textOf(read)).toContain("[1] AXButton Bold");
      const closed = await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Command+w" } });
      expect(closed.isError).toBeFalsy();
      expect(callsOf("press_key")).toContainEqual(
        expect.objectContaining({
          app: "com.apple.TextEdit",
          key: "Command+w",
          blockedBundleIds: expect.arrayContaining(["com.apple.Passwords", "com.google.Chrome", "com.apple.Safari"]),
          blockedBundleIdPrefixes: ["com.google.Chrome.app.", "com.apple.Safari.WebApp."],
        }),
      );
    });

    it("keeps a browser on the extra blocked list app_blocked, from the plugin and from the helper", async () => {
      settings = { enabled: true, extraBlockedBundleIds: ["com.google.Chrome"] };
      await restartWith({
        get_app_state: (params) => {
          if (params.app === "chrome") {
            throw new ComputerUseError({
              code: "app_blocked",
              message: "Computer Use is not allowed to use the app 'com.google.Chrome' for safety reasons.",
              bundleId: "com.google.Chrome",
            });
          }
          return createFakeHelper().helperPort.request("get_app_state", params);
        },
      });
      const client = await connect("agent-a");
      for (const app of ["Google Chrome", "com.google.Chrome", "chrome"]) {
        const refused = await client.callTool({ name: "get_app_state", arguments: { app } });
        expect(refused.structuredContent, app).toMatchObject({ error: { code: "app_blocked" } });
      }
      // Only the partial name reached the helper.
      expect(callsOf("get_app_state").map((params) => (params as { app: string }).app)).toEqual(["chrome"]);
    });

    it("treats a browser like any app when the user allows browsers", async () => {
      settings = { enabled: true, allowBrowserApps: true };
      await restartWith({ get_app_state: readAnyApp }, { waitClock: { now: () => 0, sleep: async () => {} } });
      const client = await connect("agent-a");
      const read = await client.callTool({ name: "get_app_state", arguments: { app: "com.google.Chrome" } });
      expect(textOf(read)).toContain("[1] AXButton Bold");

      for (const [name, args, cmd] of appTools("com.google.Chrome")) {
        const before = callsOf(cmd).length;
        const result = await client.callTool({ name, arguments: args });
        expect(result.isError, `${name}: ${textOf(result)}`).toBeFalsy();
        expect(callsOf(cmd).length, name).toBeGreaterThan(before);
      }
      for (const params of callsOf("get_app_state")) {
        expect((params as { blockedBundleIds: string[] }).blockedBundleIds).not.toContain("com.google.Chrome");
        expect(params).not.toHaveProperty("blockedBundleIdPrefixes");
      }
    });

    it("says in the instructions and descriptions that web pages go to Paseo's browser tools", async () => {
      const client = await connect("agent-a");
      expect(client.getInstructions()).toContain(
        "For web pages use Paseo's browser tools; Computer Use controls native apps.",
      );
      expect(client.getInstructions()).toContain("ask the user to sign in in Paseo's browser");
      expect(client.getInstructions()).toContain(
        "continue with the browser tools. If these tools are not available, ask the user to turn on browser tools in Paseo settings, or to allow web browsers in Computer Use settings.",
      );
      const { tools } = await client.listTools();
      for (const name of ["get_app_state", "press_key"]) {
        expect(tools.find((tool) => tool.name === name)?.description, name).toMatch(
          /use_browser_tools.*Paseo's browser tools/,
        );
      }
    });
  });

  it("lets the helper paste typed text when the input source is Telex, and reports the paste path", async () => {
    const telex = "com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex";
    await restartWith({
      status: () => ({
        osVersion: "15.6.0",
        axTrusted: true,
        screenCaptureGranted: true,
        abortTapAvailable: true,
        inputSourceId: telex,
        isInputMethod: true,
        helperSourceHash: "test",
      }),
      // Mirrors the helper's routing: an input method with allowInputMethod
      // false means paste.
      type_text: (params) =>
        params.allowInputMethod === false
          ? {
              ok: true,
              inputPath: "paste",
              inputSourceId: telex,
              verification: { state: "verified", reason: `field_value_read_back; pasted because input source '${telex}' is not a plain keyboard layout` },
            }
          : { ok: true, inputPath: "keys", verification: { state: "unverified", reason: "typed as keystrokes" } },
    });
    const client = await connect("agent-a");

    const typed = await client.callTool({ name: "type_text", arguments: { app: "com.apple.TextEdit", text: "xin chao" } });
    expect(callsOf("type_text")).toEqual([expect.objectContaining({ allowInputMethod: false, text: "xin chao" })]);
    expect(typed.structuredContent).toBeUndefined();
    // The text the agent reads names the path too, right after the verification line.
    expect(textOf(typed).split("\n").slice(0, 2)).toEqual([
      "verified",
      "input: pasted through the clipboard (an input method is active)",
    ]);
  });

  it("states in the text result that type_text typed keystrokes with a plain layout", async () => {
    await restartWith({
      type_text: () => ({ ok: true, inputPath: "keys", verification: { state: "verified", reason: "value_read_back" } }),
    });
    const client = await connect("agent-a");

    const typed = await client.callTool({ name: "type_text", arguments: { app: "com.apple.TextEdit", text: "hello" } });
    expect(typed.structuredContent).toBeUndefined();
    expect(textOf(typed).split("\n").slice(0, 2)).toEqual(["verified", "input: typed as keystrokes"]);
  });

  it("returns invalid_arguments when the helper rejects an unknown key name", async () => {
    await restartWith({
      press_key: () => {
        throw new ComputerUseError({ code: "malformed_request", message: "Unknown key 'hyperenter' in 'hyperenter'." });
      },
    });
    const client = await connect("agent-a");

    const pressed = await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "hyperenter" } });
    expect(pressed.structuredContent).toMatchObject({ error: { code: "invalid_arguments" } });
  });

  it("tells the agent how to convert screenshot pixels to window points", async () => {
    const tree = createFakeHelper().helperPort;
    await restartWith({
      get_app_state: async (params) => {
        const state = await tree.request("get_app_state", params);
        return {
          ...state,
          windowState: {
            ...state.windowState,
            screenshot: { url: "data:image/png;base64,AAAA", width: 800, height: 600, scale: 2 },
          },
        };
      },
    });
    settings = { enabled: true };
    const client = await connect("agent-a");

    const observed = await client.callTool({
      name: "get_app_state",
      arguments: { app: "com.apple.TextEdit", include_screenshot: true },
    });
    expect(textOf(observed)).toContain(
      "Screenshot: 1600x1200 pixels for a 800x600 point window. The tree and action tools use window points: divide a screenshot pixel position by 2.",
    );
  });

  it("rejects bad arguments with invalid_arguments", async () => {
    const client = await connect("agent-a");
    const bad = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit" } });
    expect(bad.structuredContent).toMatchObject({ error: { code: "invalid_arguments" } });
  });

  it("ignores the intent field Oh My Pi adds but still rejects other unknown keys", async () => {
    const client = await connect("agent-a");
    const withIntent = await client.callTool({
      name: "press_key",
      arguments: { app: "com.apple.TextEdit", key: "Return", i: "Pressing Return" },
    });
    expect(withIntent.isError).toBeFalsy();
    const misspelled = await client.callTool({
      name: "press_key",
      arguments: { app: "com.apple.TextEdit", key: "Return", keys: "Return" },
    });
    expect(misspelled.structuredContent).toMatchObject({ error: { code: "invalid_arguments" } });
    const nonStringIntent = await client.callTool({
      name: "status",
      arguments: { i: 1 },
    });
    expect(nonStringIntent.structuredContent).toMatchObject({ error: { code: "invalid_arguments" } });
  });

  it("lets read tools run without taking the computer", async () => {
    const reader = await connect("agent-reader");
    const owner = await connect("agent-owner");

    const read = await reader.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
    expect(read.isError).toBeFalsy();
    expect(service.controlLock.getActiveOwner().callerId).toBeNull();
    expect(fake.calls.some((call) => call.cmd === "abort_tap.arm")).toBe(false);

    // The reader did not block the next agent's action.
    const acted = await owner.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    expect(acted.isError).toBeFalsy();
    expect(service.controlLock.getActiveOwner().callerId).toBe("agent-owner");
  });

  it("releases the computer on every host turn end and re-arms Escape on the next action", async () => {
    const owner = await connect("agent-owner");
    const other = await connect("agent-other");
    const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
    const arms = () => fake.calls.filter((call) => call.cmd === "abort_tap.arm").length;

    await owner.callTool(pressReturn);
    expect(arms()).toBe(1);

    await service.onAgentTurnEnded("agent-owner");
    expect(service.controlLock.getActiveOwner().callerId).toBeNull();
    expect(fake.calls.some((call) => call.cmd === "abort_tap.disarm")).toBe(true);

    // The same agent's next turn takes the computer back with Escape armed.
    await owner.callTool(pressReturn);
    expect(arms()).toBe(2);
    await service.onAgentTurnEnded("agent-owner");

    const acted = await other.callTool(pressReturn);
    expect(acted.isError).toBeFalsy();
  });

  it("binds a caller that sends no agent id (as Codex does) through the client map", async () => {
    await service.stop();
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
      getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
      resolveAgentId: (callerId) => (callerId === "client-1" ? "agent-host-1" : null),
    });
    await service.start();
    const client = new Client({ name: "test-agent", version: "1.0.0" });
    await client.connect(new UnixSocketTransport(socketPath, { clientId: "client-1", provider: "claude" }));
    clients.push(client);

    await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    // The lock is keyed by the host agent id even though the agent never sent it.
    expect(service.controlLock.getActiveOwner()).toEqual({
      callerId: "agent-host-1",
      agentId: "agent-host-1",
    });

    await service.onAgentTurnEnded("agent-host-1");
    expect(service.controlLock.getActiveOwner().callerId).toBeNull();
  });

  it.each([
    ["claude", "Claude"],
    ["codex", "Codex"],
    ["omp", "Oh My Pi"],
    ["opencode", "Agent"],
  ])("sends the %s display name with every pointer command", async (provider, label) => {
    await service.start();
    const client = await connect(`agent-${provider}`, provider);
    await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 20, y: 30 } });
    await client.callTool({
      name: "drag",
      arguments: { app: "com.apple.TextEdit", from_x: 10, from_y: 10, to_x: 50, to_y: 60 },
    });
    await client.callTool({
      name: "scroll",
      arguments: { app: "com.apple.TextEdit", x: 20, y: 30, direction: "down", pages: 1 },
    });
    await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });

    const pointerCalls = fake.calls.filter((call) => ["click", "drag", "scroll"].includes(call.cmd));
    expect(pointerCalls.map((call) => call.cmd)).toEqual(["click", "drag", "scroll"]);
    for (const call of pointerCalls) {
      expect(call.params).toMatchObject({ overlayLabel: label });
    }
    const keyCall = fake.calls.find((call) => call.cmd === "press_key");
    expect(keyCall?.params).not.toHaveProperty("overlayLabel");
  });

  it("releases the computer when the owning connection closes", async () => {
    const owner = await connect("agent-owner");
    await owner.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    expect(service.controlLock.getActiveOwner().callerId).toBe("agent-owner");

    await owner.close();
    clients.splice(clients.indexOf(owner), 1);
    await expect
      .poll(() => service.controlLock.getActiveOwner().callerId, { timeout: 1_000 })
      .toBeNull();
  });

  it("keeps an Escape stop until the host turn ends, then allows the next turn", async () => {
    const client = await connect("agent-a");
    const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
    await client.callTool(pressReturn);
    await service.abortMonitor.triggerAbort("escape_key");

    const stopped = await client.callTool(pressReturn);
    expect(stopped.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });

    await service.onAgentTurnEnded("agent-a");
    const next = await client.callTool(pressReturn);
    expect(next.isError).toBeFalsy();
  });

  it("returns aborted_by_user when the stop lands during the read after an action", async () => {
    let clicked = false;
    fake = createFakeHelper({
      click: () => {
        clicked = true;
        return { ok: true, verification: { state: "unverified", reason: "events posted; effect not checked" } };
      },
      get_app_state: () => {
        if (clicked) {
          void service.abortMonitor.triggerAbort("escape_key");
        }
        return {
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: TEXTEDIT_TREE, screenshot: null },
        };
      },
    });
    await service.stop();
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
      getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
    });
    await service.start();
    const client = await connect("agent-a");

    const result = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
  });

  describe("overlay lifetime follows the control lock", () => {
    const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
    const endTurns = () => fake.calls.filter((call) => call.cmd === "end_turn").length;

    async function restartWith(options: {
      resolveAgentId?: (clientId: string) => string | null;
      idleLockTimeoutMs?: number;
    }) {
      await service.stop();
      fake.calls.length = 0;
      service = createComputerUseService({
        helperPort: fake.helperPort,
        socketPath,
        platformSupported: true,
        postActionSleepMs: 0,
        getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
        ...options,
      });
      await service.start();
    }

    it("hides the overlay once when the owner's turn ends", async () => {
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      expect(endTurns()).toBe(0);

      await service.onAgentTurnEnded("agent-a", "completed");
      expect(endTurns()).toBe(1);
      // A second turn end with no owner has nothing to hide.
      await service.onAgentTurnEnded("agent-a", "completed");
      expect(endTurns()).toBe(1);
    });

    it("hides the overlay once when the owning connection closes", async () => {
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      await client.close();
      clients.splice(clients.indexOf(client), 1);
      await expect.poll(() => service.controlLock.getActiveOwner().callerId, { timeout: 1_000 }).toBeNull();
      expect(endTurns()).toBe(1);
    });

    it("hides the overlay once when the lock is released for idleness", async () => {
      await restartWith({ idleLockTimeoutMs: 50 });
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      await expect.poll(() => service.controlLock.getActiveOwner().callerId, { timeout: 1_000 }).toBeNull();
      expect(endTurns()).toBe(1);
      // The later turn end finds no owner and sends nothing more.
      await service.onAgentTurnEnded("agent-a", "completed");
      expect(endTurns()).toBe(1);
    });

    it("hides the overlay once on Stop, on Escape, and on plugin stop", async () => {
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      await service.stopControl();
      expect(endTurns()).toBe(1);

      await service.onAgentTurnEnded("agent-a", "completed");
      await client.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      expect(endTurns()).toBe(2);

      await service.onAgentTurnEnded("agent-a", "completed");
      await client.callTool(pressReturn);
      await service.stop();
      expect(endTurns()).toBe(3);
    });

    it("sends nothing for a reader or for the turn end of an agent that does not own the computer", async () => {
      const reader = await connect("agent-reader");
      const owner = await connect("agent-owner");
      await reader.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
      await service.onAgentTurnEnded("agent-reader", "completed");
      expect(endTurns()).toBe(0);

      await owner.callTool(pressReturn);
      await service.onAgentTurnEnded("agent-reader", "completed");
      expect(endTurns()).toBe(0);
      expect(service.controlLock.getActiveOwner().callerId).toBe("agent-owner");
    });

    it("does not start an exited helper only to hide an overlay it no longer has", async () => {
      const listeners: Array<Parameters<HelperPort["onEvent"]>[0]> = [];
      fake.helperPort.onEvent = (listener) => {
        listeners.push(listener);
        return () => {};
      };
      const emit = (event: { event: "exited"; code: number | null; signal: string | null }) => {
        for (const listener of listeners) listener(event);
      };
      await restartWith({});
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      emit({ event: "exited", code: 1, signal: null });
      await service.onAgentTurnEnded("agent-a", "completed");
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
      expect(endTurns()).toBe(0);
    });

    it("hides the overlay of a helper that restarted while the same owner kept the lock", async () => {
      const listeners: Array<Parameters<HelperPort["onEvent"]>[0]> = [];
      fake.helperPort.onEvent = (listener) => {
        listeners.push(listener);
        return () => {};
      };
      await restartWith({});
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      for (const listener of listeners) listener({ event: "exited", code: 1, signal: null });
      // The next action re-arms Escape on the new helper, which shows the overlay again.
      await client.callTool(pressReturn);
      expect(service.controlLock.getActiveOwner().callerId).toBe("agent-a");

      await service.onAgentTurnEnded("agent-a", "completed");
      expect(endTurns()).toBe(1);
    });

    it("releases and hides when an agent closes whose caller was keyed by its client id", async () => {
      // The caller connects before the host has bound its client id, so its
      // session and the lock use the raw client id; the binding appears later.
      let bound = false;
      await restartWith({
        resolveAgentId: (clientId) => (bound && clientId === "late-client" ? "agent-late" : null),
      });
      const client = new Client({ name: "test-agent", version: "1.0.0" });
      await client.connect(new UnixSocketTransport(socketPath, { clientId: "late-client", provider: "codex" }));
      clients.push(client);
      await client.callTool(pressReturn);
      expect(service.controlLock.getActiveOwner().callerId).toBe("late-client");

      bound = true;
      await service.onAgentClosed("agent-late");
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
      expect(endTurns()).toBe(1);
    });
  });

  // The helper starts its click and scroll log when the Escape tap is armed
  // and stops it when the tap is disarmed, so these commands mark the span
  // in which the log runs.
  describe("click and scroll log runs only while an agent holds control", () => {
    const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
    const tapCommands = () =>
      fake.calls
        .map((call) => call.cmd)
        .filter((cmd) => cmd === "abort_tap.arm" || cmd === "abort_tap.disarm");

    it("is not started by a status check, the settings screen status, or a read", async () => {
      const client = await connect("agent-a");
      await client.callTool({ name: "status", arguments: {} });
      await service.getStatus();
      await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
      expect(fake.calls.some((call) => call.cmd === "status")).toBe(true);
      expect(tapCommands()).toEqual([]);
    });

    it("is not started while Computer Use is off", async () => {
      settings.enabled = false;
      const client = await connect("agent-a");
      const refused = await client.callTool(pressReturn);
      expect(textOf(refused).split("\n")[0]).toBe("error: computer_use_disabled");
      expect(tapCommands()).toEqual([]);
    });

    it("starts when an agent takes control, before its first action", async () => {
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      const cmds = fake.calls.map((call) => call.cmd);
      expect(cmds.indexOf("abort_tap.arm")).toBeGreaterThanOrEqual(0);
      expect(cmds.indexOf("abort_tap.arm")).toBeLessThan(cmds.indexOf("press_key"));
      // Later actions of the same owner keep the log running.
      await client.callTool(pressReturn);
      expect(tapCommands()).toEqual(["abort_tap.arm"]);
    });

    it("stops when control is released at the turn end, on Stop, and on Escape", async () => {
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      await service.onAgentTurnEnded("agent-a", "completed");
      expect(tapCommands()).toEqual(["abort_tap.arm", "abort_tap.disarm"]);

      await client.callTool(pressReturn);
      await service.stopControl();
      expect(tapCommands().slice(2)).toEqual(["abort_tap.arm", "abort_tap.disarm"]);

      await service.onAgentTurnEnded("agent-a", "completed");
      await client.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      expect(tapCommands().slice(4)).toEqual(["abort_tap.arm", "abort_tap.disarm"]);
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
    });

    it("stops when the owner is idle", async () => {
      await service.stop();
      fake.calls.length = 0;
      service = createComputerUseService({
        helperPort: fake.helperPort,
        socketPath,
        platformSupported: true,
        postActionSleepMs: 0,
        idleLockTimeoutMs: 50,
        getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
      });
      await service.start();
      const client = await connect("agent-a");
      await client.callTool(pressReturn);
      await expect.poll(() => service.controlLock.getActiveOwner().callerId, { timeout: 1_000 }).toBeNull();
      expect(tapCommands()).toEqual(["abort_tap.arm", "abort_tap.disarm"]);
    });
  });

  describe("Paseo Stop button", () => {
    // A type_text that runs until the plugin cancels it, like a long text
    // typed by the real helper. It records the signal the plugin passed.
    function hangingTypeText() {
      const state: { signal?: AbortSignal; started: boolean; finish: () => void } = {
        started: false,
        finish: () => {},
      };
      fake = createFakeHelper({
        type_text: (_params, options) =>
          new Promise((resolve, reject) => {
            state.started = true;
            state.signal = options?.signal;
            state.finish = () =>
              resolve({ ok: true, verification: { state: "verified", reason: "value_read_back" } });
            options?.signal?.addEventListener("abort", () => reject(options.signal?.reason), {
              once: true,
            });
          }),
      });
      return state;
    }

    async function restart(
      resolveAgentId?: (clientId: string) => string | null,
      idleLockTimeoutMs?: number,
    ) {
      await service.stop();
      service = createComputerUseService({
        helperPort: fake.helperPort,
        socketPath,
        platformSupported: true,
        postActionSleepMs: 0,
        idleLockTimeoutMs,
        getSettings: () => ({ extraBlockedBundleIds: [], screenshots: "auto" as const, ...settings }),
        resolveAgentId,
      });
      await service.start();
    }

    async function connectClientOnly(clientId: string): Promise<Client> {
      const client = new Client({ name: "test-agent", version: "1.0.0" });
      await client.connect(new UnixSocketTransport(socketPath, { clientId, provider: "codex" }));
      clients.push(client);
      return client;
    }

    const typeLong = {
      name: "type_text",
      arguments: { app: "com.apple.TextEdit", text: "a long text the user wants to stop" },
    };

    it("cancels the owner's running command within 1 s when its turn is canceled", async () => {
      const typing = hangingTypeText();
      await restart((clientId) => (clientId === "codex-client" ? "agent-codex" : null));
      const client = await connectClientOnly("codex-client");

      const call = client.callTool(typeLong);
      await expect.poll(() => typing.started).toBe(true);
      const stoppedAt = Date.now();
      await service.onAgentTurnEnded("agent-codex", "canceled");
      const result = await call;

      expect(Date.now() - stoppedAt).toBeLessThan(1_000);
      expect(result.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
      expect(typing.signal?.aborted).toBe(true);
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();

      // The stop is not kept: the agent's next turn can act again.
      const next = await client.callTool({
        name: "press_key",
        arguments: { app: "com.apple.TextEdit", key: "Return" },
      });
      expect(next.isError).toBeFalsy();
    });

    it("stops an owner that matches no agent when any agent's turn is canceled", async () => {
      const typing = hangingTypeText();
      await restart(() => null);
      const client = await connectClientOnly("unbound-client");

      const call = client.callTool(typeLong);
      await expect.poll(() => typing.started).toBe(true);
      await service.onAgentTurnEnded("some-other-agent", "canceled");

      const result = await call;
      expect(result.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
      expect(typing.signal?.aborted).toBe(true);
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
    });

    it("does not stop a known owner when a different agent's turn is canceled", async () => {
      const typing = hangingTypeText();
      await restart();
      const owner = await connect("agent-owner");

      const call = owner.callTool(typeLong);
      await expect.poll(() => typing.started).toBe(true);
      await service.onAgentTurnEnded("agent-other", "canceled");
      expect(typing.signal?.aborted).toBe(false);
      expect(service.controlLock.getActiveOwner().callerId).toBe("agent-owner");

      typing.finish();
      const result = await call;
      expect(result.isError).toBeFalsy();
    });

    it("only releases the computer on a completed turn, without a cancel", async () => {
      const client = await connect("agent-a");
      await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
      await service.onAgentTurnEnded("agent-a", "completed");

      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
      expect(fake.calls.some((call) => call.signal?.aborted)).toBe(false);
      const next = await client.callTool({
        name: "press_key",
        arguments: { app: "com.apple.TextEdit", key: "Return" },
      });
      expect(next.isError).toBeFalsy();
    });

    it("keeps the binding of an archived agent so its turns still release the computer after unarchive", async () => {
      const store = new ClientIdentityStore(dir);
      store.bind("codex-client", "agent-codex", "codex");
      store.confirm("agent-codex");
      await restart((clientId) => store.resolveAgentId(clientId));
      const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };

      const first = await connectClientOnly("codex-client");
      await first.callTool(pressReturn);
      // What the archive hook does to the service.
      await service.onAgentClosed("agent-codex");
      await first.close();
      clients.splice(clients.indexOf(first), 1);

      // Unarchive runs no plugin hook; the resumed agent reconnects with its
      // stored client id and no agent id.
      const resumed = await connectClientOnly("codex-client");
      await resumed.callTool(pressReturn);
      expect(service.controlLock.getActiveOwner().callerId).toBe("agent-codex");
      await service.onAgentTurnEnded("agent-codex", "completed");
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();

      await resumed.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      const stopped = await resumed.callTool(pressReturn);
      expect(stopped.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
      await service.onAgentTurnEnded("agent-codex", "completed");
      const next = await resumed.callTool(pressReturn);
      expect(next.isError).toBeFalsy();
    });

    it("keeps an Escape stop of a caller that matches no agent when another agent's turn ends", async () => {
      await restart(() => null);
      const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
      const client = await connectClientOnly("unbound-client");

      await client.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      const stopped = await client.callTool(pressReturn);
      expect(stopped.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });

      await service.onAgentTurnEnded("some-other-agent", "completed");
      await service.onAgentTurnEnded("some-other-agent", "canceled");
      const stillStopped = await client.callTool(pressReturn);
      expect(stillStopped.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
    });

    it("clears an Escape stop of a caller that matches no agent after it stays idle for the lock timeout", async () => {
      const idleMs = 300;
      await restart(() => null, idleMs);
      const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
      const client = await connectClientOnly("unbound-client");

      await client.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      await new Promise((resolve) => setTimeout(resolve, idleMs * 0.6));
      // A refused retry is not idle, so the wait starts again from here.
      const retry = await client.callTool(pressReturn);
      expect(retry.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
      await new Promise((resolve) => setTimeout(resolve, idleMs * 0.6));
      expect(service.abortMonitor.abortedCallerIds()).toEqual(["unbound-client"]);

      await expect
        .poll(() => service.abortMonitor.abortedCallerIds(), { timeout: idleMs * 3 })
        .toEqual([]);
      const next = await client.callTool(pressReturn);
      expect(next.isError).toBeFalsy();
    });

    it("keeps a known agent's Escape stop when a different agent's turn ends", async () => {
      await restart();
      const pressReturn = { name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } };
      const client = await connect("agent-a");

      await client.callTool(pressReturn);
      await service.abortMonitor.triggerAbort("escape_key");
      await service.onAgentTurnEnded("agent-b", "completed");
      const stillStopped = await client.callTool(pressReturn);
      expect(stillStopped.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
    });

    it("cancels the running command when the owning connection closes", async () => {
      const typing = hangingTypeText();
      await restart();
      const owner = await connect("agent-owner");

      void owner.callTool(typeLong).catch(() => {});
      await expect.poll(() => typing.started).toBe(true);
      await owner.close();
      clients.splice(clients.indexOf(owner), 1);

      await expect.poll(() => typing.signal?.aborted, { timeout: 1_000 }).toBe(true);
      // A closed connection is not a Stop press, so the reason says so.
      expect(String(typing.signal?.reason)).toContain("connection to Computer Use closed");
      expect(String(typing.signal?.reason)).not.toContain("pressed Stop");
      await expect
        .poll(() => service.controlLock.getActiveOwner().callerId, { timeout: 1_000 })
        .toBeNull();
    });
  });
  describe("sparse tree screenshot", () => {
    const SCREENSHOT = { url: "data:image/png;base64,AAAA", width: 800, height: 600, scale: 2 };
    const buttons = (count: number) => ({
      ...TEXTEDIT_TREE,
      root: {
        ...TEXTEDIT_TREE.root,
        children: [
          {
            native_id: "4242:0",
            role: "AXWindow",
            name: "Canvas",
            bounds: { x: 0, y: 25, width: 800, height: 600 },
            children: Array.from({ length: count }, (_, i) => ({
              native_id: `4242:0.${i}`,
              role: "AXButton",
              name: `Tool ${i}`,
              bounds: { x: 10 * i, y: 30, width: 8, height: 8 },
              actions: ["AXPress"],
            })),
          },
        ],
      },
    });
    const withTree = (count: number, screenCaptureGranted = true): Partial<Handlers> => ({
      get_app_state: (params) => ({
        app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
        windowState: {
          text: "App: TextEdit (pid: 4242, window: 42)",
          rawTree: buttons(count),
          screenshot: params.includeScreenshot && screenCaptureGranted ? SCREENSHOT : null,
        },
      }),
      status: () => ({
        osVersion: "15.6.0",
        axTrusted: true,
        screenCaptureGranted,
        abortTapAvailable: true,
        inputSourceId: "com.apple.keylayout.ABC",
        isInputMethod: false,
        helperSourceHash: "test",
      }),
    });
    const imagesOf = (result: Awaited<ReturnType<Client["callTool"]>>) =>
      (Array.isArray(result.content) ? result.content : []).filter(
        (item: { type?: string }) => item.type === "image",
      );
    const read = (client: Client) =>
      client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });

    it("attaches a screenshot in auto mode when the window has 2 indexed elements", async () => {
      await restartWith(withTree(2));
      const result = await read(await connect("agent-a"));
      expect(imagesOf(result)).toHaveLength(1);
      expect(textOf(result)).toContain("Screenshot: 1600x1200 pixels");
    });

    it("attaches none at 3 indexed elements unless the agent asks", async () => {
      await restartWith(withTree(3));
      const client = await connect("agent-a");
      expect(imagesOf(await read(client))).toHaveLength(0);
      const asked = await client.callTool({
        name: "get_app_state",
        arguments: { app: "com.apple.TextEdit", include_screenshot: true },
      });
      expect(imagesOf(asked)).toHaveLength(1);
    });

    it("never attaches one when screenshots are off, and always attaches one when they are always on", async () => {
      settings = { enabled: true, screenshots: "never" };
      await restartWith(withTree(0));
      const client = await connect("agent-a");
      const refused = await client.callTool({
        name: "get_app_state",
        arguments: { app: "com.apple.TextEdit", include_screenshot: true },
      });
      expect(imagesOf(refused)).toHaveLength(0);
      expect(callsOf("get_app_state")).toEqual([expect.objectContaining({ includeScreenshot: false })]);

      settings = { enabled: true, screenshots: "always" };
      await restartWith(withTree(5));
      expect(imagesOf(await read(await connect("agent-b")))).toHaveLength(1);
    });

    it("attaches one to the state after an action too", async () => {
      await restartWith(withTree(2));
      const client = await connect("agent-a");
      const clicked = await client.callTool({
        name: "click",
        arguments: { app: "com.apple.TextEdit", x: 5, y: 5 },
      });
      expect(textOf(clicked).split("\n")[0]).toBe("verified");
      expect(imagesOf(clicked)).toHaveLength(1);
    });

    it("attaches one to the state after an action in always mode too, and not in never mode", async () => {
      settings = { enabled: true, screenshots: "always" };
      await restartWith(withTree(2));
      const always = await (await connect("agent-a")).callTool({
        name: "click",
        arguments: { app: "com.apple.TextEdit", x: 5, y: 5 },
      });
      expect(imagesOf(always)).toHaveLength(1);

      settings = { enabled: true, screenshots: "never" };
      await restartWith(withTree(2));
      const never = await (await connect("agent-b")).callTool({
        name: "click",
        arguments: { app: "com.apple.TextEdit", x: 5, y: 5 },
      });
      expect(imagesOf(never)).toHaveLength(0);
    });

    it("lets visual_changed see a change the last action already made", async () => {
      let captures = 0;
      await restartWith({
        ...withTree(2),
        "capture.signature": () => ({
          // The first image is the one taken before the click; the later ones show the result.
          signature: Buffer.alloc(64 * 40, captures++ === 0 ? 20 : 220).toString("base64"),
          width: 64,
          height: 40,
          windowId: 42,
          windowWidth: 800,
          windowHeight: 600,
        }),
      });
      const client = await connect("agent-a");
      await read(client);
      await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
      const started = Date.now();
      const result = await client.callTool({
        name: "wait_for",
        arguments: { app: "com.apple.TextEdit", any: [{ name: "redrawn", visual_changed: {} }], timeout_ms: 5_000 },
      });
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({
        met: "redrawn",
        baseline: "before_last_action",
      });
      expect(Date.now() - started).toBeLessThan(1_000);
    });

    it("makes visual_changed wait for a new change once the agent has read the state after the action", async () => {
      let captures = 0;
      await restartWith({
        ...withTree(2),
        "capture.signature": () => ({
          signature: Buffer.alloc(64 * 40, captures++ === 0 ? 20 : 220).toString("base64"),
          width: 64,
          height: 40,
          windowId: 42,
          windowWidth: 800,
          windowHeight: 600,
        }),
      });
      const client = await connect("agent-a");
      await read(client);
      await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
      await read(client);
      const result = await client.callTool({
        name: "wait_for",
        arguments: { app: "com.apple.TextEdit", any: [{ name: "redrawn", visual_changed: {} }], timeout_ms: 1_000 },
      });
      const outcome = JSON.parse(textOf(result).split("\n")[0]!);
      expect(outcome.met).toBeNull();
      expect(outcome.baseline).toBe("wait_start");
    });

    it("returns the tree with one line naming Screen Recording when it is not granted", async () => {
      await restartWith(withTree(1, false));
      const result = await read(await connect("agent-a"));
      expect(result.isError).toBeFalsy();
      expect(imagesOf(result)).toHaveLength(0);
      const text = textOf(result);
      expect(text).toContain("[0] AXButton Tool 0");
      expect(text.split("\n").filter((line) => line.includes("Screen Recording"))).toHaveLength(1);
    });
  });

  describe("wait_for", () => {
    const waitFor = (client: Client, args: Record<string, unknown>) =>
      client.callTool({ name: "wait_for", arguments: { app: "com.apple.TextEdit", ...args } });

    it("is a read-only tool and the instructions explain the coordinate fallback", async () => {
      const client = await connect("agent-a");
      const { tools } = await client.listTools();
      expect(tools.find((tool) => tool.name === "wait_for")?.annotations).toMatchObject({
        readOnlyHint: true,
        destructiveHint: false,
      });
      expect(client.getInstructions()).toMatch(/few or no elements.*includes a screenshot.*x and y window coordinates/s);
    });

    it("returns the condition that was met with the index the agent already holds", async () => {
      // A clock that does not move: the time the first read takes would
      // otherwise show in waited_ms.
      await restartWith({}, { waitClock: { now: () => 0, sleep: async () => {} } });
      const client = await connect("agent-a");
      await client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });
      const result = await waitFor(client, {
        any: [{ name: "bold ready", appears: { role: "AXButton", name: "bold" } }],
      });
      expect(result.isError).toBeFalsy();
      expect(result.structuredContent).toBeUndefined();
      const [json, note] = textOf(result).split("\n");
      expect(JSON.parse(json!)).toEqual({ met: "bold ready", waited_ms: 0, element_index: 1 });
      expect(note).toMatch(/UI language/);

      const clicked = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", element_index: 1 } });
      expect(clicked.isError).toBeFalsy();
      expect(callsOf("click")).toEqual([expect.objectContaining({ nativeId: "4242:0.0" })]);
    });

    it("says so when the matched element has no index in the agent's last read", async () => {
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        any: [{ name: "bold ready", appears: { role: "AXButton", name: "bold" } }],
      });
      const body = JSON.parse(textOf(result).split("\n")[0]!);
      expect(body).not.toHaveProperty("element_index");
      expect(body.note).toMatch(/Call get_app_state for indexes/);
    });

    it("reports a timeout as a normal result", async () => {
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        any: [{ name: "sheet", appears: { role: "AXSheet" } }],
        timeout_ms: 1,
      });
      expect(result.isError).toBeFalsy();
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({ met: null, reason: "timeout" });
    });

    it("takes no control lock and arms no Escape tap", async () => {
      const client = await connect("agent-a");
      await waitFor(client, { any: [{ name: "bold", appears: { name: "Bold" } }] });
      expect(service.controlLock.getActiveOwner().callerId).toBeNull();
      expect(fake.calls.some((call) => call.cmd === "abort_tap.arm")).toBe(false);
    });

    it("refuses a blocked app without calling the helper", async () => {
      settings = { enabled: true, extraBlockedBundleIds: ["com.example.Vault"] };
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        app: "com.example.vault",
        any: [{ name: "x", appears: { role: "AXSheet" } }],
      });
      expect(result.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
      expect(fake.calls).toEqual([]);
    });

    it("ends with aborted_by_user when Stop reaches the caller, at the next poll", async () => {
      let reads = 0;
      await restartWith({
        get_app_state: (params, options) => {
          reads += 1;
          if (reads === 2) {
            void service.abortMonitor.triggerAbort("stop_button", "agent-a");
          }
          return createFakeHelper().helperPort.request("get_app_state", params, options);
        },
      });
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        any: [{ name: "sheet", appears: { role: "AXSheet" } }],
        timeout_ms: 30_000,
      });
      expect(result.isError).toBe(true);
      expect(result.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
      expect(reads).toBe(2);
    });

    it("ends with aborted_by_user when Escape stops the agent that holds the computer", async () => {
      let reads = 0;
      await restartWith({
        get_app_state: (params, options) => {
          reads += 1;
          if (reads === 3) {
            // The Escape tap reports against the lock owner.
            void service.abortMonitor.triggerAbort("escape_key");
          }
          return createFakeHelper().helperPort.request("get_app_state", params, options);
        },
      });
      const client = await connect("agent-a");
      await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
      expect(service.controlLock.getActiveOwner().callerId).toBe("agent-a");
      reads = 0;
      const result = await waitFor(client, {
        any: [{ name: "sheet", appears: { role: "AXSheet" } }],
        timeout_ms: 30_000,
      });
      expect(result.structuredContent).toMatchObject({ error: { code: "aborted_by_user" } });
    });

    it("is not ended by Escape when another agent holds the computer; Escape stops the owner only", async () => {
      let reads = 0;
      let escaped = false;
      await restartWith({
        get_app_state: async (params, options) => {
          reads += 1;
          if (reads === 2 && !escaped) {
            escaped = true;
            // Agent b owns the lock, so the stop lands on b, not on the waiting agent a.
            await service.abortMonitor.triggerAbort("escape_key", "agent-b");
          }
          return createFakeHelper().helperPort.request("get_app_state", params, options);
        },
      });
      const waiter = await connect("agent-a");
      const owner = await connect("agent-b");
      await owner.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
      reads = 0;
      const result = await waitFor(waiter, {
        any: [{ name: "sheet", appears: { role: "AXSheet" } }],
        timeout_ms: 700,
      });
      expect(escaped).toBe(true);
      expect(result.isError).toBeFalsy();
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({ met: null, reason: "timeout" });
    });

    it("returns app_not_running when the app is not running", async () => {
      await restartWith({
        get_app_state: () => {
          throw new ComputerUseError({ code: "app_not_found", message: "No running app matches 'Notes'." });
        },
      });
      const client = await connect("agent-a");
      const result = await waitFor(client, { app: "Notes", any: [{ name: "x", appears: { role: "AXSheet" } }] });
      expect(result.isError).toBeFalsy();
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({ met: null, reason: "app_not_running" });
    });

    it("compares window images through the helper for visual conditions", async () => {
      let captures = 0;
      await restartWith({
        "capture.signature": () => ({
          signature: Buffer.alloc(64 * 40, captures++ === 0 ? 20 : 220).toString("base64"),
          width: 64,
          height: 40,
          windowId: 42,
          windowWidth: 800,
          windowHeight: 600,
        }),
      });
      const client = await connect("agent-a");
      const region = { x: 0, y: 0, width: 100, height: 50 };
      const result = await waitFor(client, {
        window_id: 42,
        any: [{ name: "redrawn", visual_changed: { region } }],
        timeout_ms: 5_000,
      });
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({ met: "redrawn", baseline: "wait_start" });
      expect(callsOf("capture.signature")[0]).toMatchObject({ app: "com.apple.TextEdit", windowId: 42, region });
      expect(fake.calls.some((call) => call.cmd === "get_app_state")).toBe(false);
    });

    it("names the baseline in a visual_changed timeout", async () => {
      await restartWith({
        "capture.signature": () => ({
          signature: Buffer.alloc(64 * 40, 20).toString("base64"),
          width: 64,
          height: 40,
          windowId: 42,
          windowWidth: 800,
          windowHeight: 600,
        }),
      });
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        window_id: 42,
        any: [{ name: "redrawn", visual_changed: {} }],
        timeout_ms: 1_000,
      });
      expect(JSON.parse(textOf(result).split("\n")[0]!)).toMatchObject({
        met: null,
        reason: "timeout",
        baseline: "wait_start",
      });
    });

    it("ends a visual wait at once when the helper loses Screen Recording or refuses the region", async () => {
      for (const [code, expected] of [
        ["permission_missing", "permission_missing"],
        ["malformed_request", "invalid_arguments"],
      ] as const) {
        await restartWith({
          "capture.signature": () => {
            throw new ComputerUseError({ code, message: "refused" });
          },
        });
        const client = await connect(`agent-${code}`);
        const started = Date.now();
        const result = await waitFor(client, {
          any: [{ name: "calm", visual_stable: { quiet_ms: 300 } }],
          timeout_ms: 30_000,
        });
        expect(result.structuredContent).toMatchObject({ error: { code: expected } });
        expect(Date.now() - started).toBeLessThan(2_000);
      }
    });

    it("returns permission_missing for a visual condition without Screen Recording", async () => {
      await restartWith({
        status: () => ({
          osVersion: "15.6.0",
          axTrusted: true,
          screenCaptureGranted: false,
          abortTapAvailable: true,
          inputSourceId: "x",
          isInputMethod: false,
          helperSourceHash: "t",
        }),
      });
      const client = await connect("agent-a");
      const result = await waitFor(client, { any: [{ name: "calm", visual_stable: { quiet_ms: 300 } }] });
      expect(result.structuredContent).toMatchObject({ error: { code: "permission_missing" } });
      expect(callsOf("capture.signature")).toEqual([]);
    });

    it("refuses a blocked app before it checks Screen Recording for a visual condition", async () => {
      settings = { enabled: true, extraBlockedBundleIds: ["com.example.Vault"] };
      const client = await connect("agent-a");
      const result = await waitFor(client, {
        app: "com.example.vault",
        any: [{ name: "calm", visual_stable: { quiet_ms: 300 } }],
      });
      expect(result.structuredContent).toMatchObject({ error: { code: "app_blocked" } });
      expect(fake.calls).toEqual([]);
    });

    it.each([
      ["no conditions", { any: [] }],
      ["5 conditions", { any: Array.from({ length: 5 }, (_, i) => ({ name: `c${i}`, appears: { role: "AXSheet" } })) }],
      ["two conditions in one entry", { any: [{ name: "a", appears: { role: "AXSheet" }, stable: { quiet_ms: 300 } }] }],
      ["an element condition with no selector", { any: [{ name: "a", appears: {} }] }],
      ["both value tests", { any: [{ name: "a", value: { role: "AXTextField", value_equals: "x", value_contains: "y" } }] }],
      ["an empty value_equals", { any: [{ name: "a", value: { role: "AXTextField", value_equals: "" } }] }],
      ["a quiet period under 100 ms", { any: [{ name: "a", stable: { quiet_ms: 99 } }] }],
      ["a timeout over 30 s", { any: [{ name: "a", appears: { role: "AXSheet" } }], timeout_ms: 30_001 }],
      ["a describe condition", { any: [{ name: "a", describe: "a spinner" }] }],
      [
        "two conditions with the same name",
        { any: [{ name: "Done", appears: { role: "AXSheet" } }, { name: "done", disappears: { role: "AXSheet" } }] },
      ],
    ])("refuses %s", async (_label, args) => {
      const client = await connect("agent-a");
      const result = await waitFor(client, args);
      expect(result.structuredContent).toMatchObject({ error: { code: "invalid_arguments" } });
      expect(fake.calls).toEqual([]);
    });
  });
  describe("changes seen after actions the helper cannot check", () => {
    const UNCHECKED = {
      ok: true as const,
      verification: { state: "unverified" as const, reason: "events posted; effect not checked" },
    };
    // The first window is the one the tree shows (id 42); the others are listed
    // as other windows, with the ids 43 and up, as the helper reports them.
    const treeWith = (windows: string[], field = ""): RawAXTree => ({
      window_id: 42,
      window_title: windows[0]!,
      other_windows: windows.slice(1).map((title, i) => ({ id: 43 + i, title })),
      root: {
        native_id: "4242:",
        role: "AXApplication",
        children: [
          {
            native_id: "4242:0",
            role: "AXWindow",
            name: windows[0]!,
            window_id: 42,
            bounds: { x: 0, y: 25, width: 800, height: 600 },
            states: ["enabled"],
            actions: ["AXRaise"],
            children: [
              { native_id: "4242:0.0", role: "AXButton", name: "One", actions: ["AXPress"], states: ["enabled"] },
              { native_id: "4242:0.1", role: "AXButton", name: "Two", actions: ["AXPress"], states: ["enabled"] },
              { native_id: "4242:0.2", role: "AXTextField", name: "Field", value: field, states: ["enabled"] },
              { native_id: "4242:0.3", role: "AXButton", name: "Three", actions: ["AXPress"], states: ["enabled"] },
            ],
          },
        ],
      },
    });
    // The tree the helper returns changes when the action runs.
    function withAction(
      before: RawAXTree,
      after: RawAXTree,
      overrides: Partial<Handlers> = {},
      reason = "events posted; effect not checked",
      // Whether the app was in front before the action; unset leaves it out.
      appWasActive?: boolean,
    ): Partial<Handlers> {
      let acted = false;
      const act = () => {
        acted = true;
        return { ...UNCHECKED, verification: { state: "unverified" as const, reason } };
      };
      return {
        press_key: act,
        click: act,
        type_text: () => {
          acted = true;
          return { ok: true, verification: { state: "unverified", reason: "no focused text field to read back" } };
        },
        get_app_state: () => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          ...(appWasActive !== undefined ? { isActive: acted ? true : appWasActive } : {}),
          windowState: { text: "App: TextEdit", rawTree: acted ? after : before, screenshot: null },
        }),
        ...overrides,
      };
    }
    const press = (client: Client) =>
      client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
    const read = (client: Client) =>
      client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit" } });

    it("says a window opened", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"])));
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await press(client)).split("\n")[0]).toBe('changed: window opened [43] "Settings"');
    });

    it("says a window closed", async () => {
      await restartWith(withAction(treeWith(["Canvas", "Settings"]), treeWith(["Canvas"])));
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await press(client)).split("\n")[0]).toBe('changed: window closed [43] "Settings"');
    });

    it("says a title changed", async () => {
      await restartWith(withAction(treeWith(["Canvas 0"]), treeWith(["Canvas 1"])));
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await press(client)).split("\n")[0]).toBe('changed: title "Canvas 0" -> "Canvas 1"');
    });

    it("says every change on its own line", async () => {
      await restartWith(withAction(treeWith(["Canvas 3", "Suggestions"]), treeWith(["Canvas 0"])));
      const client = await connect("agent-a");
      await read(client);
      const lines = textOf(await press(client)).split("\n");
      expect(lines.slice(0, 2)).toEqual(['changed: window closed [43] "Suggestions"', 'changed: title "Canvas 3" -> "Canvas 0"']);
    });

    it("says the content changed after a coordinate click", async () => {
      await restartWith(withAction(treeWith(["Canvas"], "a"), treeWith(["Canvas"], "b")));
      const client = await connect("agent-a");
      await read(client);
      const clicked = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
      expect(textOf(clicked).split("\n")[0]).toBe("changed: content");
    });

    // A menu bar whose Edit menu is closed, holding the named items.
    const withMenu = (tree: RawAXTree, items: string[]): RawAXTree => ({
      ...tree,
      root: {
        native_id: "4242:",
        role: "AXApplication",
        children: [
          ...(tree.root?.children ?? []),
          {
            native_id: "4242:m",
            role: "AXMenuBar",
            children: [
              {
                native_id: "4242:m.0",
                role: "AXMenuBarItem",
                name: "Edit",
                actions: ["AXPress"],
                children: [
                  {
                    native_id: "4242:m.0.m",
                    role: "AXMenu",
                    children: items.map((name, i) => ({
                      native_id: `4242:m.0.m.${i}`,
                      role: "AXMenuItem",
                      name,
                      actions: ["AXPress"],
                    })),
                  },
                ],
              },
            ],
          },
        ],
      },
    });
    const clickOnce = (client: Client) =>
      client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });

    it("says menu items changed, not content, when only items of a menu that is not printed differ", async () => {
      await restartWith(
        withAction(withMenu(treeWith(["Canvas"]), ["Undo", "Redo"]), withMenu(treeWith(["Canvas"]), ["Undo Typing", "Redo"])),
      );
      const client = await connect("agent-a");
      await read(client);
      const clicked = textOf(await clickOnce(client));
      expect(clicked.split("\n")[0]).toBe("changed: menu items");
      expect(clicked).toContain("No accessibility changes.");
    });

    it("never says content when the printed diff is empty", async () => {
      // The agent read state A, the app moved to B before the action, and the
      // action brought it back to A: the state before the action differs from
      // the state after it, and the agent sees no difference.
      let reads = 0;
      const stateA = treeWith(["Canvas"], "a");
      const stateB = treeWith(["Canvas"], "b");
      await restartWith({
        ...withAction(stateA, stateA),
        get_app_state: () => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: reads++ === 1 ? stateB : stateA, screenshot: null },
        }),
      });
      const client = await connect("agent-a");
      await read(client);
      const clicked = textOf(await clickOnce(client));
      expect(clicked.split("\n")[0]).toBe("unverified: no change seen");
      expect(clicked).toContain("No accessibility changes.");
    });

    describe("a click on an app that was not in front", () => {
      const NOTE =
        "The app was not active; this click may only have activated its window. If nothing happened, click again.";

      it("adds one line when nothing but focus or menus changed", async () => {
        await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"]), {}, undefined, false));
        const client = await connect("agent-a");
        await read(client);
        expect(textOf(await clickOnce(client)).split("\n").slice(0, 2)).toEqual(["unverified: no change seen", NOTE]);
      });

      it("adds it to a menu items change too", async () => {
        await restartWith(
          withAction(
            withMenu(treeWith(["Canvas"]), ["Undo"]),
            withMenu(treeWith(["Canvas"]), ["Undo Typing"]),
            {},
            undefined,
            false,
          ),
        );
        const client = await connect("agent-a");
        await read(client);
        expect(textOf(await clickOnce(client)).split("\n").slice(0, 2)).toEqual(["changed: menu items", NOTE]);
      });

      it("leaves it out when a window opened, when content changed, or when the app was in front", async () => {
        await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"]), {}, undefined, false));
        let client = await connect("agent-a");
        await read(client);
        expect(textOf(await clickOnce(client))).not.toContain(NOTE);

        await restartWith(withAction(treeWith(["Canvas"], "a"), treeWith(["Canvas"], "b"), {}, undefined, false));
        client = await connect("agent-b");
        await read(client);
        expect(textOf(await clickOnce(client))).not.toContain(NOTE);

        await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"]), {}, undefined, true));
        client = await connect("agent-c");
        await read(client);
        expect(textOf(await clickOnce(client))).not.toContain(NOTE);
      });

      it("leaves it out when the app is still not active after the click", async () => {
        // The plugin acts without raising windows, so a background app stays
        // in the background: that says nothing about the click.
        const same = treeWith(["Canvas"]);
        await restartWith({
          ...withAction(same, same),
          get_app_state: () => ({
            app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
            isActive: false,
            windowState: { text: "App: TextEdit", rawTree: same, screenshot: null },
          }),
        });
        const client = await connect("agent-a");
        await read(client);
        const clicked = textOf(await clickOnce(client));
        expect(clicked.split("\n")[0]).toBe("unverified: no change seen");
        expect(clicked).not.toContain(NOTE);
      });

      it("leaves it out for a sparse app, whose tree shows no change whatever the click did", async () => {
        const sparse: RawAXTree = { ...treeWith(["Canvas"]), root: { ...treeWith(["Canvas"]).root!, children: [] } };
        await restartWith(withAction(sparse, sparse, {}, undefined, false));
        const client = await connect("agent-a");
        await read(client);
        expect(textOf(await clickOnce(client))).not.toContain(NOTE);
      });

      it("leaves it out for a key press and when the helper does not say whether the app was in front", async () => {
        await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"]), {}, undefined, false));
        let client = await connect("agent-a");
        await read(client);
        expect(textOf(await press(client))).not.toContain(NOTE);

        await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"])));
        client = await connect("agent-b");
        await read(client);
        expect(textOf(await clickOnce(client))).not.toContain(NOTE);
      });
    });

    it("keeps unverified, with a new reason, when nothing differs", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"])));
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await press(client)).split("\n")[0]).toBe("unverified: no change seen");
    });

    it("lets the helper's own verification win over a difference", async () => {
      await restartWith(
        withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"]), {
          click: () => ({ ok: true, verification: { state: "verified", reason: "ax_press_succeeded" } }),
        }),
      );
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 1, y: 1 } })).split("\n")[0]).toBe("verified");
    });

    it("keeps any other unverified reason as the helper wrote it", async () => {
      await restartWith(
        withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"]), {}, "the key went to another app"),
      );
      const client = await connect("agent-a");
      await read(client);
      expect(textOf(await press(client)).split("\n")[0]).toBe("unverified: the key went to another app");
    });

    it("also replaces the reason of an accepted element action that was not checked", async () => {
      await restartWith(
        withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"]), {}, "action accepted, effect not checked"),
      );
      const client = await connect("agent-a");
      await read(client);
      const clicked = await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 1, y: 1 } });
      expect(textOf(clicked).split("\n")[0]).toBe('changed: window opened [43] "Settings"');
    });

    it("keeps the helper's reason for an action that checks its own result", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"])));
      const client = await connect("agent-a");
      await read(client);
      const typed = await client.callTool({ name: "type_text", arguments: { app: "com.apple.TextEdit", text: "x" } });
      expect(textOf(typed).split("\n")[0]).toBe("unverified: no focused text field to read back");
    });

    it("keeps the helper's reason when no earlier read gives something to compare", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"])));
      const client = await connect("agent-a");
      expect(textOf(await press(client)).split("\n")[0]).toBe("unverified: events posted; effect not checked");
    });

    it("costs one extra read for a key press and none for typing", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas"])));
      const client = await connect("agent-a");
      await read(client);
      const reads = () => callsOf("get_app_state").length;
      const start = reads();
      await press(client);
      expect(reads() - start).toBe(2);
      const afterPress = reads();
      await client.callTool({ name: "type_text", arguments: { app: "com.apple.TextEdit", text: "x" } });
      expect(reads() - afterPress).toBe(1);
    });

    it("does not carry a state from one action into the next", async () => {
      await restartWith(withAction(treeWith(["Canvas"]), treeWith(["Canvas", "Settings"])));
      const client = await connect("agent-a");
      await read(client);
      await press(client);
      const typed = await client.callTool({ name: "type_text", arguments: { app: "com.apple.TextEdit", text: "x" } });
      expect(textOf(typed).split("\n")[0]).toBe("unverified: no focused text field to read back");
    });

    it("tells agents to treat changed as evidence, not proof", async () => {
      const client = await connect("agent-a");
      expect(client.getInstructions()).toMatch(/`changed:`.*evidence.*not proof/s);
    });
  });

  describe("windows of one app", () => {
    // Three windows; the helper shows one per read, the one named by windowId or else the focused one.
    let windows: Array<{ id: number; title: string }>;
    let focused: number;
    const windowTree = (id: number): RawAXTree => {
      const shown = windows.find((window) => window.id === id)!;
      return {
        window_id: id,
        window_title: shown.title,
        other_windows: windows.filter((window) => window.id !== id),
        focused_window: windows.find((window) => window.id === focused),
        root: {
          native_id: "4242:",
          role: "AXApplication",
          children: [
            {
              native_id: "4242:0",
              role: "AXWindow",
              name: shown.title,
              window_id: id,
              bounds: { x: 0, y: 0, width: 800, height: 600 },
              children: [
                { native_id: "4242:0.0", role: "AXButton", name: `Go ${shown.title}`, actions: ["AXPress"], bounds: { x: 1, y: 1, width: 40, height: 20 } },
                { native_id: "4242:0.1", role: "AXButton", name: "Two", actions: ["AXPress"], bounds: { x: 1, y: 30, width: 40, height: 20 } },
                { native_id: "4242:0.2", role: "AXButton", name: "Three", actions: ["AXPress"], bounds: { x: 1, y: 60, width: 40, height: 20 } },
              ],
            },
          ],
        },
      };
    };
    const unchecked = { ok: true as const, verification: { state: "unverified" as const, reason: "events posted; effect not checked" } };
    const gone = (id: number) => new ComputerUseError({ code: "window_gone", message: `Window ${id} is closed.` });
    const read = (client: Client, extra: Record<string, unknown> = {}) =>
      client.callTool({ name: "get_app_state", arguments: { app: "com.apple.TextEdit", ...extra } });

    beforeEach(async () => {
      windows = [
        { id: 42, title: "Canvas 4" },
        { id: 43, title: "Mail" },
        { id: 44, title: "VEED" },
      ];
      focused = 42;
      const open = (id: number | undefined) => {
        const target = id ?? focused;
        if (!windows.some((window) => window.id === target)) throw gone(target);
        return target;
      };
      const act = (params: { windowId?: number }) => {
        open(params.windowId);
        return unchecked;
      };
      await restartWith({
        get_app_state: (params) => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(open(params.windowId)), screenshot: null },
        }),
        click: act,
        drag: act,
        scroll: act,
        press_key: act,
        type_text: act,
        paste_text: act,
        set_value: act,
        select_text: act,
        perform_secondary_action: act,
      });
    });

    it("prints one window, the menu bar's place aside, and the others on one line", async () => {
      const client = await connect("agent-a");
      const text = textOf(await read(client));
      expect(text).toContain('Other windows: [43] "Mail", [44] "VEED"');
      expect(text).toContain("Go Canvas 4");
      expect(text).not.toContain("Go Mail");
    });

    it("reads the window the agent names, and acts there afterwards", async () => {
      const client = await connect("agent-a");
      const text = textOf(await read(client, { window_id: 43 }));
      expect(text).toContain("Go Mail");
      expect(text).toContain('Other windows: [42] "Canvas 4", [44] "VEED"');
      await client.callTool({ name: "click", arguments: { app: "com.apple.TextEdit", x: 5, y: 5 } });
      expect(callsOf("click")).toEqual([expect.objectContaining({ windowId: 43 })]);
    });

    it("keeps acting in the window it read after the app focuses another one, and says so", async () => {
      const client = await connect("agent-a");
      await read(client);
      // The app moves its focus while the key is handled.
      await restartWith({
        get_app_state: (params) => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(params.windowId ?? focused), screenshot: null },
        }),
        press_key: () => {
          focused = 44;
          return unchecked;
        },
      });
      const next = await connect("agent-b");
      await read(next);
      const pressed = textOf(await next.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } }));
      expect(callsOf("press_key")).toEqual([expect.objectContaining({ windowId: 42 })]);
      expect(pressed.split("\n")).toContain('focused window is now [44] "VEED"');
      // The read after the key is still of window 42, whose tree did not change.
      expect(pressed).toContain("No accessibility changes.");
      expect(callsOf("get_app_state").at(-1)).toMatchObject({ windowId: 42 });
    });

    it("passes window_id of every action tool to the helper", async () => {
      const client = await connect("agent-a");
      await read(client);
      const calls: Array<[string, string, Record<string, unknown>]> = [
        ["click", "click", { x: 1, y: 1 }],
        ["drag", "drag", { from_x: 1, from_y: 1, to_x: 2, to_y: 2 }],
        ["scroll", "scroll", { direction: "down", x: 1, y: 1 }],
        ["press_key", "press_key", { key: "Return" }],
        ["type_text", "type_text", { text: "a" }],
        ["paste_text", "paste_text", { text: "a" }],
      ];
      for (const [tool, cmd, args] of calls) {
        await client.callTool({ name: tool, arguments: { app: "com.apple.TextEdit", window_id: 44, ...args } });
        expect(callsOf(cmd as HelperCommandName).at(-1), tool).toMatchObject({ windowId: 44 });
      }
      await read(client, { window_id: 44 });
      for (const [tool, cmd, args] of [
        ["set_value", "set_value", { element_index: 0, value: "v" }],
        ["select_text", "select_text", { element_index: 0, text: "v" }],
        ["secondary_action", "perform_secondary_action", { element_index: 0, action: "AXShowMenu" }],
      ] as const) {
        await client.callTool({ name: tool, arguments: { app: "com.apple.TextEdit", window_id: 44, ...args } });
        expect(callsOf(cmd as HelperCommandName).at(-1), tool).toMatchObject({ windowId: 44 });
      }
    });

    it("lists window_id on every action tool and on get_app_state", async () => {
      const client = await connect("agent-a");
      const { tools } = await client.listTools();
      for (const name of [...MUTATING_TOOL_NAMES, "get_app_state"]) {
        const tool = tools.find((entry) => entry.name === name)!;
        expect(Object.keys((tool.inputSchema.properties ?? {}) as object), name).toContain("window_id");
      }
    });

    it("returns window_gone, and acts nowhere else, when the window it read is closed", async () => {
      const client = await connect("agent-a");
      await read(client);
      windows = windows.filter((window) => window.id !== 42);
      focused = 43;
      for (const [name, args] of [
        ["click", { x: 1, y: 1 }],
        ["press_key", { key: "Return" }],
        ["type_text", { text: "a" }],
      ] as const) {
        const result = await client.callTool({ name, arguments: { app: "com.apple.TextEdit", ...args } });
        expect(result.isError, name).toBe(true);
        expect(textOf(result), name).toContain("error: window_gone");
      }
      for (const call of [...callsOf("click"), ...callsOf("press_key"), ...callsOf("type_text")]) {
        expect(call).toMatchObject({ windowId: 42 });
      }
      // A new read picks a window that exists.
      expect(textOf(await read(client))).toContain("Go Mail");
    });

    it("reports a window the action closed, with its id, and reads no other window", async () => {
      const client = await connect("agent-a");
      await read(client);
      await restartWith({
        get_app_state: (params) => {
          if (params.windowId === 42 && closed) throw gone(42);
          return {
            app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
            windowState: { text: "App: TextEdit", rawTree: windowTree(params.windowId ?? focused), screenshot: null },
          };
        },
        press_key: () => {
          closed = true;
          return unchecked;
        },
      });
      let closed = false;
      const again = await connect("agent-b");
      await read(again);
      const pressed = textOf(await again.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Command+w" } }));
      const lines = pressed.split("\n");
      expect(lines[0]).toBe('changed: window closed [42] "Canvas 4"');
      expect(pressed).toContain("Call get_app_state");
      expect(pressed).not.toContain("Go Mail");
    });

    // The close of a window as Chrome shows it: the first read after the
    // action still lists the window, with no elements left, so the tree is
    // sparse; the read for its image no longer finds it.
    async function restartClosingWindow(cmd: "click" | "press_key" | "perform_secondary_action", reason: string) {
      let acted = false;
      let readsAfter = 0;
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          if (acted && params.windowId === 42) {
            readsAfter += 1;
            if (readsAfter > 1) throw gone(42);
            const closing: RawAXTree = {
              window_id: 42,
              window_title: "Canvas 4",
              other_windows: windows.filter((window) => window.id !== 42),
              root: { native_id: "4242:", role: "AXApplication", children: [] },
            };
            return { app, windowState: { text: "App: TextEdit", rawTree: closing, screenshot: null } };
          }
          return { app, windowState: { text: "App: TextEdit", rawTree: windowTree(params.windowId ?? focused), screenshot: null } };
        },
        [cmd]: () => {
          acted = true;
          return { ok: true, verification: { state: "unverified", reason } };
        },
      } as Partial<Handlers>);
    }

    for (const [tool, cmd, args, reason] of [
      ["press_key", "press_key", { key: "Command+w" }, "events posted; effect not checked"],
      ["click", "click", { element_index: 1 }, "action accepted, effect not checked"],
      ["secondary_action", "perform_secondary_action", { element_index: 1, action: "AXPress" }, "action accepted, effect not checked"],
    ] as const) {
      it(`reports the target window closed by ${tool} when the window is gone only at the read for the image`, async () => {
        await restartClosingWindow(cmd, reason);
        const client = await connect("agent-a");
        await read(client, { window_id: 42 });
        const result = await client.callTool({ name: tool, arguments: { app: "com.apple.TextEdit", window_id: 42, ...args } });
        expect(result.isError).toBeFalsy();
        const lines = textOf(result).split("\n");
        expect(lines[0]).toBe('changed: window closed [42] "Canvas 4"');
        expect(textOf(result)).toContain("Call get_app_state");
        expect(textOf(result)).not.toContain("State unavailable");
      });
    }

    it("says the window was closed with its close button when Command+w could not reach it", async () => {
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          const id = params.windowId ?? focused;
          if (!windows.some((window) => window.id === id)) throw gone(id);
          return { app, windowState: { text: "App: TextEdit", rawTree: windowTree(id), screenshot: null } };
        },
        press_key: () => {
          windows = windows.filter((window) => window.id !== 43);
          return { ok: true, verification: { state: "unverified", reason: "closed with its close button" } };
        },
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 43 });
      const text = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 43, key: "Command+w" } }),
      );
      expect(text.split("\n")[0]).toBe('changed: window closed [43] "Mail" (closed with its close button)');
      expect(text).toContain("Call get_app_state");
    });

    it("does not show a window an earlier result reported closed in the next read", async () => {
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          const id = params.windowId ?? focused;
          if (!windows.some((window) => window.id === id)) throw gone(id);
          return { app, windowState: { text: "App: TextEdit", rawTree: windowTree(id), screenshot: null } };
        },
        press_key: () => {
          windows = windows.filter((window) => window.id !== 43);
          return unchecked;
        },
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 43 });
      const closed = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 43, key: "Command+w" } }),
      );
      expect(closed.split("\n")[0]).toBe('changed: window closed [43] "Mail"');
      const next = textOf(await read(client));
      expect(next).toContain("Go Canvas 4");
      expect(next).not.toContain("Mail");
    });

    it("keeps the helper's line when the close button left the window open", async () => {
      await restartWith({
        get_app_state: (params) => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(params.windowId ?? focused), screenshot: null },
        }),
        press_key: () => ({
          ok: true,
          verification: { state: "unverified", reason: "pressed the close button of window [43]; the window is still open" },
        }),
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 43 });
      const text = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 43, key: "Command+w" } }),
      );
      expect(text.split("\n")[0]).toBe("unverified: pressed the close button of window [43]; the window is still open");
    });

    it("reports the window closed when it closed after the helper's wait", async () => {
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          const id = params.windowId ?? focused;
          if (!windows.some((window) => window.id === id)) throw gone(id);
          return { app, windowState: { text: "App: TextEdit", rawTree: windowTree(id), screenshot: null } };
        },
        press_key: () => {
          // Still on screen when the helper's wait ended, gone by the read.
          windows = windows.filter((window) => window.id !== 43);
          return {
            ok: true,
            verification: { state: "unverified", reason: "pressed the close button of window [43]; the window is still open" },
          };
        },
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 43 });
      const text = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 43, key: "Command+w" } }),
      );
      expect(text.split("\n")[0]).toBe('changed: window closed [43] "Mail" (closed with its close button)');
      expect(text).not.toContain("still open");
    });

    it("keeps the helper's line when a timed out close button press leaves the state unknown", async () => {
      await restartWith({
        get_app_state: (params) => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(params.windowId ?? focused), screenshot: null },
        }),
        press_key: () => ({
          ok: true,
          verification: { state: "unverified", reason: "close button pressed, window state unknown" },
        }),
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 43 });
      const text = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 43, key: "Command+w" } }),
      );
      expect(text.split("\n")[0]).toBe("unverified: close button pressed, window state unknown");
      expect(text).not.toContain("No keys were sent");
    });

    it("reads again when the focused window is not listed yet, and reports it opened", async () => {
      let acted = false;
      let readsAfter = 0;
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          const tree = windowTree(params.windowId ?? focused);
          if (acted) {
            readsAfter += 1;
            // The first read lists the windows before the new one is on the list.
            if (readsAfter === 1) tree.other_windows = tree.other_windows!.filter((window) => window.id !== 45);
          }
          return { app, windowState: { text: "App: TextEdit", rawTree: tree, screenshot: null } };
        },
        press_key: () => {
          acted = true;
          windows.push({ id: 45, title: "New Tab" });
          focused = 45;
          return unchecked;
        },
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 42 });
      const text = textOf(
        await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 42, key: "Command+n" } }),
      );
      const lines = text.split("\n");
      expect(lines[0]).toBe('changed: window opened [45] "New Tab"');
      expect(lines).toContain('focused window is now [45] "New Tab"');
      expect(readsAfter).toBe(2);
      // The state is a diff with the last read: the new Other windows line names it.
      expect(lines.some((line) => line.includes("Other windows:") && line.includes('[45] "New Tab"'))).toBe(true);
    });

    it("stops reading again after three tries when the focused window never shows on the list", async () => {
      let acted = false;
      let readsAfter = 0;
      const app = { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" };
      await restartWith({
        get_app_state: (params) => {
          const tree = windowTree(params.windowId ?? focused);
          if (acted) {
            readsAfter += 1;
            tree.focused_window = { id: 99, title: "Elsewhere" };
          }
          return { app, windowState: { text: "App: TextEdit", rawTree: tree, screenshot: null } };
        },
        press_key: () => {
          acted = true;
          return unchecked;
        },
      });
      const client = await connect("agent-a");
      await read(client, { window_id: 42 });
      const result = await client.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", window_id: 42, key: "Return" } });
      expect(result.isError).toBeFalsy();
      expect(readsAfter).toBe(4);
    });

    it("keeps the helper's reason when it could not focus the window", async () => {
      const client = await connect("agent-a");
      await read(client);
      await restartWith({
        get_app_state: () => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(42), screenshot: null },
        }),
        press_key: () => ({ ok: true, verification: { state: "unverified", reason: "could not focus window [42]" } }),
      });
      const reread = await connect("agent-b");
      await read(reread);
      const pressed = await reread.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
      expect(textOf(pressed).split("\n")[0]).toBe("unverified: could not focus window [42]");
    });

    it("tells the agent when the app in front of the user changed during an action", async () => {
      const client = await connect("agent-a");
      await read(client);
      await restartWith({
        get_app_state: () => ({
          app: { bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit" },
          windowState: { text: "App: TextEdit", rawTree: windowTree(42), screenshot: null },
        }),
        press_key: () => ({
          ok: true,
          verification: { state: "unverified", reason: "events posted; effect not checked" },
          userFocusChanged: "user_focus_changed: com.apple.Safari -> com.apple.TextEdit",
          focusWatchDetail: "focus_watch: restored key_down_idle=100.000s mouse_down_idle=2.050s",
        }),
      });
      const reread = await connect("agent-b");
      await read(reread);
      const pressed = await reread.callTool({ name: "press_key", arguments: { app: "com.apple.TextEdit", key: "Return" } });
      expect(textOf(pressed).split("\n")).toContain("user_focus_changed: com.apple.Safari -> com.apple.TextEdit");
      // The idle times are for the audit log only.
      expect(textOf(pressed)).not.toContain("focus_watch");
    });
  });

  describe("pause while the user is interacting", () => {
    const USER_ACTIVE_MESSAGE =
      "The user is using TextEdit. Wait a few seconds, call get_app_state again, then retry.";
    const STALE_STATE_MESSAGE =
      "The app may have changed while the user was working. Call get_app_state, then retry.";
    const DETAIL = "user_active: rule=key_frontmost key_down_idle=1.000s mouse_down_idle=infs scroll_idle=infs pause=3.000s";
    const app = "com.apple.TextEdit";
    let userActive = false;

    // Like the helper: while the user is active every action command is
    // refused before it does anything, and read commands are never refused.
    beforeEach(async () => {
      userActive = false;
      const act = () => {
        if (userActive) {
          throw new ComputerUseError({ code: "user_active", message: USER_ACTIVE_MESSAGE, userActivityDetail: DETAIL });
        }
        return { ok: true as const, verification: { state: "verified" as const, reason: "value_read_back" } };
      };
      await restartWith({
        click: act,
        drag: act,
        scroll: act,
        press_key: act,
        type_text: act,
        paste_text: act,
        set_value: act,
        select_text: act,
        perform_secondary_action: act,
      });
    });

    const actions: Array<[string, Record<string, unknown>]> = [
      ["click", { app, element_index: 1 }],
      ["drag", { app, from_x: 10, from_y: 10, to_x: 50, to_y: 50 }],
      ["scroll", { app, direction: "down", element_index: 2 }],
      ["press_key", { app, key: "Return" }],
      ["type_text", { app, text: "hi" }],
      ["paste_text", { app, text: "hi" }],
      ["set_value", { app, element_index: 2, value: "hi" }],
      ["select_text", { app, element_index: 2, text: "hel" }],
      ["secondary_action", { app, element_index: 1, action: "AXShowMenu" }],
    ];

    it("refuses every action with user_active and still serves every read tool", async () => {
      userActive = true;
      const client = await connect("agent-a");
      expect(actions.map(([name]) => name).sort()).toEqual([...MUTATING_TOOL_NAMES].sort());
      for (const [name, args] of actions) {
        const read = await client.callTool({ name: "get_app_state", arguments: { app } });
        expect(read.isError, name).toBeFalsy();
        const refused = await client.callTool({ name, arguments: args });
        expect(refused.isError, name).toBe(true);
        expect(textOf(refused), name).toBe(`error: user_active\n${USER_ACTIVE_MESSAGE}`);
        // The idle times go to the audit log only.
        expect(textOf(refused), name).not.toMatch(/\d/);
        expect(refused.structuredContent, name).toEqual({ error: { code: "user_active", message: USER_ACTIVE_MESSAGE } });
      }
      for (const [name, args] of [
        ["status", {}],
        ["list_apps", {}],
        ["list_windows", { app }],
        ["wait_for", { app, any: [{ name: "sheet", appears: { role: "AXSheet" } }], timeout_ms: 1 }],
      ] as const) {
        const result = await client.callTool({ name, arguments: args });
        expect(result.isError, name).toBeFalsy();
      }

      const refusals = service.getAuditLog().filter((entry) => entry.status === "refused");
      expect(refusals.map((entry) => entry.toolName)).toEqual(actions.map(([name]) => name));
      for (const entry of refusals) {
        expect(entry).toMatchObject({ refusal: "user_active", userActivityDetail: DETAIL });
      }
    });

    it("refuses the next action with stale_state until the agent reads the app again", async () => {
      const client = await connect("agent-a");
      await client.callTool({ name: "get_app_state", arguments: { app } });
      userActive = true;
      const refused = await client.callTool({ name: "click", arguments: { app, element_index: 1 } });
      expect(textOf(refused).split("\n")[0]).toBe("error: user_active");

      // The user stopped, but the agent did not look at the app again.
      userActive = false;
      const stale = await client.callTool({ name: "click", arguments: { app, element_index: 1 } });
      expect(stale.isError).toBe(true);
      expect(textOf(stale)).toBe(`error: stale_state\n${STALE_STATE_MESSAGE}`);
      const typed = await client.callTool({ name: "type_text", arguments: { app, text: "hi" } });
      expect(textOf(typed).split("\n")[0]).toBe("error: stale_state");
      // A wait reads the app but is not a read the agent sees.
      const waited = await client.callTool({
        name: "wait_for",
        arguments: { app, any: [{ name: "sheet", appears: { role: "AXSheet" } }], timeout_ms: 1 },
      });
      expect(waited.isError).toBeFalsy();
      const stillStale = await client.callTool({ name: "click", arguments: { app, element_index: 1 } });
      expect(textOf(stillStale).split("\n")[0]).toBe("error: stale_state");
      // Only the refused click reached the helper; no event was sent for the others.
      expect(callsOf("click")).toHaveLength(1);
      expect(callsOf("type_text")).toHaveLength(0);

      await client.callTool({ name: "get_app_state", arguments: { app } });
      const clicked = await client.callTool({ name: "click", arguments: { app, element_index: 1 } });
      expect(clicked.isError).toBeFalsy();
      expect(textOf(clicked).split("\n")[0]).toBe("verified");
      expect(callsOf("click")).toHaveLength(2);

      const entries = service.getAuditLog().filter((entry) => entry.toolName !== "get_app_state" && entry.toolName !== "wait_for");
      expect(entries.map((entry) => [entry.toolName, entry.status, entry.refusal])).toEqual([
        ["click", "refused", "user_active"],
        ["click", "refused", "stale_state"],
        ["type_text", "refused", "stale_state"],
        ["click", "refused", "stale_state"],
        ["click", "completed", undefined],
      ]);
      expect(entries[0]?.userActivityDetail).toBe(DETAIL);
      expect(entries[1]).not.toHaveProperty("userActivityDetail");
    });

    it("allows the action after a new read once the user is idle", async () => {
      const client = await connect("agent-a");
      userActive = true;
      const refused = await client.callTool({ name: "press_key", arguments: { app, key: "Return" } });
      expect(textOf(refused).split("\n")[0]).toBe("error: user_active");
      userActive = false;
      // Read by display name: the refusal named the bundle id.
      await client.callTool({ name: "get_app_state", arguments: { app: "TextEdit" } });
      const pressed = await client.callTool({ name: "press_key", arguments: { app, key: "Return" } });
      expect(pressed.isError).toBeFalsy();
      expect(callsOf("press_key")).toHaveLength(2);
    });

    it("tells the agent what both codes mean", async () => {
      const client = await connect("agent-a");
      expect(client.getInstructions()).toMatch(/`user_active`.*get_app_state.*`stale_state`/);
    });
  });
});
