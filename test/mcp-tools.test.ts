import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ComputerUseError } from "../server/computer-use-mcp/contract/errors";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";
import type {
  HelperCommandName,
  HelperCommands,
} from "../server/computer-use-mcp/contract/helper-protocol";
import { type ComputerUseService, createComputerUseService } from "../server/computer-use-mcp";
import { MUTATING_TOOL_NAMES, READ_TOOL_NAMES } from "../server/computer-use-mcp/mcp/tools";
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
  let settings: { enabled: boolean; extraBlockedBundleIds?: string[] };
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

  async function restartWith(overrides: Partial<Handlers>): Promise<void> {
    await service.stop();
    fake = createFakeHelper(overrides);
    service = createComputerUseService({
      helperPort: fake.helperPort,
      socketPath,
      platformSupported: true,
      postActionSleepMs: 0,
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
        overlayLabel: "Claude",
        nativeId: "4242:0.0",
        expected: { role: "AXButton", name: "Bold", frame: { x: 10, y: 30, width: 40, height: 20 } },
      },
    ]);

    await client.callTool({ name: "set_value", arguments: { app: "TextEdit", element_index: 2, value: "hi" } });
    expect(callsOf("set_value")).toEqual([
      {
        app: "TextEdit",
        blockedBundleIds: expect.arrayContaining(["com.apple.Passwords"]),
        nativeId: "4242:0.1",
        expected: { role: "AXTextArea", frame: { x: 10, y: 60, width: 780, height: 540 } },
        value: "hi",
      },
    ]);
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
      arguments: { app: "com.apple.Safari", element_index: 1 },
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
});
