import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { ClientIdentityStore } from "../server/paseo/identity-store";
import {
  MUTATING_TOOL_NAMES,
  READ_TOOL_NAMES,
} from "../server/computer-use-mcp/mcp/tools";
import {
  addComputerUseServer,
  COMPUTER_USE_SERVER_KEY,
  type AgentCreateRequest,
} from "../server/paseo/inject";
import { computerUseSettingsSchema } from "../shared/settings";
import type { ComputerUseSettingsValues } from "../shared/settings";

const defaultSettings: ComputerUseSettingsValues = {
  enabled: true,
  injectProviders: ["claude", "codex", "omp"],
  extraBlockedBundleIds: [],
  screenshots: "auto",
  allowBrowserApps: false,
};

describe("addComputerUseServer", () => {
  it("does not inject when disabled", () => {
    const req: AgentCreateRequest = {
      config: { provider: "claude", cwd: "/repo" },
    };
    const res = addComputerUseServer(
      req,
      { ...defaultSettings, enabled: false },
      {
        clientId: "client-1",
        shimPath: "/bin/paseo-computer-use-mcp",
        socketPath: "/tmp/mcp.sock",
      },
    );
    expect(res).toBe(req);
  });

  it("injects the stdio MCP entry and preapproves only the read tools", () => {
    const req: AgentCreateRequest = {
      config: {
        provider: "claude",
        cwd: "/repo",
        mcpServers: {
          existing: { type: "http", url: "https://example.com" },
        },
      },
      env: { FOO: "bar" },
    };

    const res = addComputerUseServer(req, defaultSettings, {
      clientId: "client-abc",
      shimPath: "/state/bin/paseo-computer-use-mcp",
      socketPath: "/state/mcp.sock",
    });

    expect(res.env).toEqual({
      FOO: "bar",
      PASEO_CU_CLIENT: "client-abc",
    });
    expect(res.config.mcpServers?.existing).toEqual({
      type: "http",
      url: "https://example.com",
    });
    expect(res.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toEqual({
      type: "stdio",
      command: "/state/bin/paseo-computer-use-mcp",
      args: [
        "--mcp-proxy",
        "--socket",
        "/state/mcp.sock",
        "--client",
        "client-abc",
        "--provider",
        "claude",
      ],
    });
    expect(res.config.toolPolicy?.preapproved).toEqual([
      { kind: "mcp", server: "paseo-computer", tool: "status" },
      { kind: "mcp", server: "paseo-computer", tool: "list_apps" },
      { kind: "mcp", server: "paseo-computer", tool: "list_windows" },
      { kind: "mcp", server: "paseo-computer", tool: "get_app_state" },
      { kind: "mcp", server: "paseo-computer", tool: "wait_for" },
    ]);
  });

  it("never preapproves a mutating tool, so a prompting provider asks first", () => {
    for (const provider of ["claude"]) {
      const res = addComputerUseServer(
        { config: { provider, cwd: "/repo" } },
        defaultSettings,
        { clientId: "client-m", shimPath: "/shim", socketPath: "/sock" },
      );
      const preapproved = (res.config.toolPolicy?.preapproved ?? []).map((item) => item.tool);
      expect(preapproved.sort()).toEqual([...READ_TOOL_NAMES].sort());
      for (const tool of MUTATING_TOOL_NAMES) {
        expect(preapproved).not.toContain(tool);
      }
    }
  });

  it("injects for codex without a tool policy, so codex lists the action tools", () => {
    // Paseo's codex adapter turns preapproved tools into an enabled_tools
    // allowlist; a policy with only the read tools would hide every action.
    const res = addComputerUseServer(
      { config: { provider: "codex", cwd: "/repo" } },
      defaultSettings,
      { clientId: "client-c", shimPath: "/shim", socketPath: "/sock" },
    );
    expect(res.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toMatchObject({
      type: "stdio",
      args: expect.arrayContaining(["--provider", "codex"]),
    });
    expect(res.config.toolPolicy).toBeUndefined();
  });

  it("injects for omp without a tool policy, since that adapter ignores it", () => {
    const res = addComputerUseServer(
      { config: { provider: "omp", cwd: "/repo" } },
      defaultSettings,
      { clientId: "client-o", shimPath: "/shim", socketPath: "/sock" },
    );
    expect(res.config.mcpServers?.[COMPUTER_USE_SERVER_KEY]).toBeDefined();
    expect(res.config.toolPolicy).toBeUndefined();
  });

  it("defaults to claude, codex, and omp", () => {
    expect(computerUseSettingsSchema.parse({}).injectProviders).toEqual(["claude", "codex", "omp"]);
  });

  it("does not inject for providers outside the MCP-capable set, even when listed", () => {
    const req: AgentCreateRequest = {
      config: { provider: "custom-acp", cwd: "/repo" },
    };
    const res = addComputerUseServer(
      req,
      { ...defaultSettings, injectProviders: ["custom-acp"] },
      {
        clientId: "client-2",
        shimPath: "/state/bin/paseo-computer-use-mcp",
        socketPath: "/state/mcp.sock",
      },
    );
    expect(res).toBe(req);
  });
});

describe("ClientIdentityStore", () => {
  it("resolves a binding at once but persists it only after the agent is confirmed", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "paseo-cu-id-"));
    try {
      const store1 = new ClientIdentityStore(dir);
      store1.bind("client-100", "agent-999", "codex");
      expect(store1.resolveAgentId("client-100")).toBe("agent-999");
      expect(new ClientIdentityStore(dir).resolveAgentId("client-100")).toBeNull();

      expect(store1.confirm("agent-999")).toBe(true);

      const store2 = new ClientIdentityStore(dir);
      expect(store2.resolveAgentId("client-100")).toBe("agent-999");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
