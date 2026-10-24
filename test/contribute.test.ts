import { createPaseoClient } from "@getpaseo/client";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type {
  PluginBeforeRequests,
  PluginHookAgent,
  PluginLifecycleEvents,
  PluginHookContext,
  PluginServerContext,
  PluginSettings,
  PluginSettingsState,
} from "@getpaseo/plugin/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { COMPUTER_USE_SERVER_KEY } from "../server/paseo/inject";
import { ClientIdentityStore } from "../server/paseo/identity-store";

// A real swiftc build is slow and machine dependent. A failing build also
// checks that a helper build failure does not crash the plugin process.
vi.mock("../server/computer-use-mcp/helper/build", async (importOriginal) => {
  const original = await importOriginal<typeof import("../server/computer-use-mcp/helper/build")>();
  return {
    ...original,
    buildHelperBinary: () => Promise.reject(new Error("swiftc is not available in tests")),
  };
});

// Records every service the plugin creates, so a test can check what the
// host hooks pass to it.
const createdServices = vi.hoisted(() => [] as Array<import("../server/computer-use-mcp").ComputerUseService>);
vi.mock("../server/computer-use-mcp", async (importOriginal) => {
  const original = await importOriginal<typeof import("../server/computer-use-mcp")>();
  return {
    ...original,
    createComputerUseService: (deps: Parameters<typeof original.createComputerUseService>[0]) => {
      const service = original.createComputerUseService(deps);
      createdServices.push(service);
      return service;
    },
  };
});

// Take the schema constraint from the SDK itself so the fake uses the same zod
// types as the host contract.
type SdkSchema = Parameters<PluginServerContext["registerSettings"]>[0]["schema"];

type BeforeHandler<Name extends keyof PluginBeforeRequests> = (
  input: { request: PluginBeforeRequests[Name] },
  context: PluginHookContext,
) => PluginBeforeRequests[Name] | void | Promise<PluginBeforeRequests[Name] | void>;

// One list per hook name keeps each handler paired with its own request type.
type BeforeRegistry = { [Name in keyof PluginBeforeRequests]: Array<BeforeHandler<Name>> };

type EventHandler<Name extends keyof PluginLifecycleEvents> = (
  event: PluginLifecycleEvents[Name],
  context: PluginHookContext,
) => void | Promise<void>;

type EventRegistry = { [Name in keyof PluginLifecycleEvents]: Array<EventHandler<Name>> };

function createFakeServer(
  options: { storedValues?: unknown; readGate?: Promise<void> } = {},
) {
  const beforeHandlers: BeforeRegistry = {
    "agent.create": [],
    "agent.session_open": [],
    "workspace.create": [],
  };
  const settingsEmitters: Array<(values: unknown) => Promise<void>> = [];
  const lifecycleEvents: string[] = [];
  const eventHandlers: EventRegistry = {
    "agent.turn_started": [],
    "agent.turn_ended": [],
    "agent.permission_requested": [],
    "agent.permission_resolved": [],
    "agent.archived": [],
    "agent.created": [],
    "agent.closed": [],
    "workspace.created": [],
    "workspace.archived": [],
  };

  const server: PluginServerContext = {
    registerSettings<Schema extends SdkSchema>(definition: { schema: Schema }): PluginSettings<Schema> {
      const listeners = new Set<(state: PluginSettingsState<Schema>) => void | Promise<void>>();
      let revision = 1;
      settingsEmitters.push(async (values: unknown) => {
        revision += 1;
        const state: PluginSettingsState<Schema> = {
          status: "ready",
          revision: String(revision),
          values: definition.schema.parse(values),
        };
        for (const listener of listeners) await listener(state);
      });
      return {
        read: async () => {
          await options.readGate;
          return {
            status: "ready",
            revision: "1",
            values: definition.schema.parse(options.storedValues ?? {}),
          };
        },
        subscribe: (listener: (state: PluginSettingsState<Schema>) => void | Promise<void>) => {
          listeners.add(listener);
          return () => {
            listeners.delete(listener);
          };
        },
      };
    },
    handle: () => {},
    registerProvider: () => {},
    registerUsageSource: () => {},
    on: (name, handler) => {
      lifecycleEvents.push(name);
      eventHandlers[name].push(handler);
      return () => {};
    },
    before: (name, handler) => {
      beforeHandlers[name].push(handler);
      return () => {};
    },
  };

  return {
    server,
    agentCreateHook: () => beforeHandlers["agent.create"][0],
    sessionOpenHook: () => beforeHandlers["agent.session_open"][0],
    emit: async <Name extends keyof PluginLifecycleEvents>(
      name: Name,
      event: PluginLifecycleEvents[Name],
    ) => {
      for (const handler of eventHandlers[name]) await handler(event, hookContext);
    },
    lifecycleEvents,
    emitSettings: async (values: unknown) => {
      for (const emit of settingsEmitters) await emit(values);
    },
  };
}

// The agent.create hook never calls the Paseo API, so an unconnected client
// is enough to satisfy the hook context.
const hookContext: PluginHookContext = {
  paseo: createPaseoClient({ url: "ws://127.0.0.1:1" }),
  signal: new AbortController().signal,
};

describe("contribute", () => {
  let homeDir: string;
  let previousHome: string | undefined;

  beforeEach(() => {
    homeDir = mkdtempSync(path.join(tmpdir(), "paseo-cu-home-"));
    previousHome = process.env.HOME;
    process.env.HOME = homeDir;
  });

  afterEach(() => {
    process.env.HOME = previousHome;
    rmSync(homeDir, { recursive: true, force: true });
  });

  it("starts without throwing and applies settings changes to agent.create", async () => {
    const { default: contribute } = await import("../index.server");
    const fake = createFakeServer();

    const cleanup = contribute(fake.server);
    try {
      const createHook = fake.agentCreateHook();
      expect(createHook).toBeDefined();
      if (!createHook) return;

      const request: PluginBeforeRequests["agent.create"] = {
        config: { provider: "claude", cwd: "/repo" },
      };

      await fake.emitSettings({ enabled: false });
      const disabled = await createHook({ request }, hookContext);
      expect(disabled?.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toBeUndefined();

      await fake.emitSettings({ enabled: true });
      const enabled = await createHook({ request }, hookContext);
      expect(enabled?.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toMatchObject({
        type: "stdio",
      });
    } finally {
      await cleanup();
    }
  });

  it("waits for stored settings before deciding whether to inject at startup", async () => {
    const { default: contribute } = await import("../index.server");
    let openReadGate: () => void = () => {};
    const readGate = new Promise<void>((resolve) => {
      openReadGate = resolve;
    });
    // Stored settings say enabled, but the first read is still in flight when
    // the first agent is created.
    const fake = createFakeServer({ storedValues: { enabled: true }, readGate });

    const cleanup = contribute(fake.server);
    try {
      const createHook = fake.agentCreateHook();
      expect(createHook).toBeDefined();
      if (!createHook) return;

      const pending = createHook(
        { request: { config: { provider: "claude", cwd: "/repo" } } },
        hookContext,
      );
      openReadGate();
      const created = await pending;
      expect(created?.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toMatchObject({
        type: "stdio",
      });
    } finally {
      await cleanup();
    }
  });
  it("subscribes to the host turn-end hook so every turn end releases the computer", async () => {
    const { default: contribute } = await import("../index.server");
    const fake = createFakeServer();
    const cleanup = contribute(fake.server);
    try {
      expect(fake.lifecycleEvents).toContain("agent.turn_ended");
    } finally {
      await cleanup();
    }
  });

  describe("client -> agent identity binding", () => {
    function hookAgent(id: string, provider = "codex"): PluginHookAgent {
      return { id, workspaceId: null, parentAgentId: null, provider, cwd: "/repo", title: null };
    }

    function stateDir(): string {
      const root = path.join(homeDir, ".local", "state", "paseo-computer-use");
      const [entry] = readdirSync(root);
      return path.join(root, entry ?? "");
    }

    // Runs the host's create sequence: agent.create, then session_open with
    // the env the create hook returned. No PASEO_AGENT_ID is involved, as for
    // Codex, whose MCP shim does not receive it.
    async function createAgent(fake: ReturnType<typeof createFakeServer>, agentId: string) {
      const createHook = fake.agentCreateHook();
      const sessionOpenHook = fake.sessionOpenHook();
      if (!createHook || !sessionOpenHook) throw new Error("hooks not registered");
      const created = await createHook(
        { request: { config: { provider: "codex", cwd: "/repo" } } },
        hookContext,
      );
      const clientId = created?.env?.PASEO_CU_CLIENT;
      if (!clientId) throw new Error("no client id injected");
      await sessionOpenHook(
        {
          request: {
            agentId,
            workspaceId: null,
            provider: "codex",
            cwd: "/repo",
            reason: "create",
            purpose: "interactive",
            env: created?.env ?? {},
          },
        },
        hookContext,
      );
      return clientId;
    }

    it("keeps the binding across a daemon restart and after archive", async () => {
      const { default: contribute } = await import("../index.server");
      const fake = createFakeServer({ storedValues: { enabled: true } });
      const cleanup = contribute(fake.server);
      let clientId = "";
      try {
        clientId = await createAgent(fake, "agent-codex-1");
        // Not on disk until the host confirms the agent exists.
        expect(new ClientIdentityStore(stateDir()).resolveAgentId(clientId)).toBeNull();
        await fake.emit("agent.created", { agent: hookAgent("agent-codex-1") });
        // A daemon shutdown closes every agent; that must not drop the map.
        await fake.emit("agent.closed", { agent: hookAgent("agent-codex-1") });
      } finally {
        await cleanup();
      }

      // A new plugin process, as after a restart, reads the persisted map.
      expect(new ClientIdentityStore(stateDir()).resolveAgentId(clientId)).toBe("agent-codex-1");

      const restarted = createFakeServer({ storedValues: { enabled: true } });
      const cleanupRestarted = contribute(restarted.server);
      try {
        await restarted.emit("agent.archived", {
          agent: hookAgent("agent-codex-1"),
          archivedAt: new Date().toISOString(),
        });
      } finally {
        await cleanupRestarted();
      }
      // The host can unarchive the agent with no plugin hook, and it then
      // reconnects with the same client id, so the binding must still resolve.
      expect(new ClientIdentityStore(stateDir()).resolveAgentId(clientId)).toBe("agent-codex-1");
    });

    it("passes the canceled outcome of a turn end to the service", async () => {
      const { default: contribute } = await import("../index.server");
      const fake = createFakeServer();
      const cleanup = contribute(fake.server);
      try {
        const service = createdServices.at(-1);
        if (!service) throw new Error("no service created");
        const onTurnEnded = vi.spyOn(service, "onAgentTurnEnded");
        await fake.emit("agent.turn_ended", {
          agent: hookAgent("agent-x"),
          turnId: null,
          outcome: { kind: "canceled", reason: "user" },
          timeline: [],
        });
        expect(onTurnEnded).toHaveBeenCalledWith("agent-x", "canceled");
      } finally {
        await cleanup();
      }
    });
  });
});
