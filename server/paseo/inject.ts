import type { PluginBeforeRequests } from "@getpaseo/plugin/server";
import { SUPPORTED_PROVIDERS, type ComputerUseSettingsValues } from "../../shared/settings";
import { READ_TOOL_NAMES } from "../computer-use-mcp/mcp/tools";

export const COMPUTER_USE_SERVER_KEY = "paseo-computer";
// Providers whose Paseo adapter accepts injected MCP servers and that this
// plugin supports. Derived from the settings list so a provider shown on the
// settings screen always gets the server.
export const MCP_SERVER_PROVIDERS: ReadonlySet<string> = new Set(
  SUPPORTED_PROVIDERS.map((provider) => provider.id),
);
// Providers that get the read tools preapproved. Claude treats a preapproved
// tool as "do not prompt" and still lists every other tool. Codex is left out:
// its Paseo adapter turns the preapproved list into an enabled_tools
// allowlist, which would hide every action tool from the agent. Providers
// without a policy still get the server; their permission mode decides what
// prompts.
export const TOOL_POLICY_SUPPORTED_PROVIDERS = new Set(["claude"]);
// Only tools that cannot change the screen are preapproved. Mutating tools
// stay unapproved so a prompting provider asks the user before each action.
export const PREAPPROVED_TOOLS: readonly string[] = READ_TOOL_NAMES;

export type AgentCreateRequest = PluginBeforeRequests["agent.create"];

export function addComputerUseServer(
  request: AgentCreateRequest,
  settings: ComputerUseSettingsValues,
  options: {
    clientId: string;
    shimPath: string;
    socketPath: string;
  },
): AgentCreateRequest {
  if (!settings.enabled) {
    return request;
  }

  const provider = request.config.provider;
  if (!MCP_SERVER_PROVIDERS.has(provider) || !settings.injectProviders.includes(provider)) {
    return request;
  }

  const mcpEntry = {
    type: "stdio" as const,
    command: options.shimPath,
    args: [
      "--mcp-proxy",
      "--socket",
      options.socketPath,
      "--client",
      options.clientId,
      "--provider",
      provider,
    ],
  };

  const nextMcpServers = {
    ...request.config.mcpServers,
    [COMPUTER_USE_SERVER_KEY]: mcpEntry,
  };

  let nextToolPolicy = request.config.toolPolicy;
  if (TOOL_POLICY_SUPPORTED_PROVIDERS.has(provider)) {
    const existingPreapproved = request.config.toolPolicy?.preapproved ?? [];
    const seen = new Set(existingPreapproved.map((item) => `${item.kind}:${item.server}:${item.tool}`));
    const merged = [...existingPreapproved];
    for (const tool of PREAPPROVED_TOOLS) {
      const key = `mcp:${COMPUTER_USE_SERVER_KEY}:${tool}`;
      if (!seen.has(key)) {
        seen.add(key);
        merged.push({
          kind: "mcp",
          server: COMPUTER_USE_SERVER_KEY,
          tool,
        });
      }
    }
    nextToolPolicy = {
      ...request.config.toolPolicy,
      preapproved: merged,
    };
  }

  return {
    ...request,
    env: {
      ...request.env,
      PASEO_CU_CLIENT: options.clientId,
    },
    config: {
      ...request.config,
      mcpServers: nextMcpServers,
      ...(nextToolPolicy !== undefined ? { toolPolicy: nextToolPolicy } : {}),
    },
  };
}
