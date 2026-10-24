import { createHash, randomUUID } from "node:crypto";
import { constants, copyFileSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import type { PluginServerContext, PluginSettingsState } from "@getpaseo/plugin/server";
import {
  computerUseSettings,
  computerUseSettingsSchema,
  type ComputerUseSettingsValues,
} from "./shared/settings";
import { createComputerUseService } from "./server/computer-use-mcp";
import { buildHelperBinary } from "./server/computer-use-mcp/helper/build";
import { installMcpShim } from "./server/computer-use-mcp/helper/install-shim";
import { HelperProcess } from "./server/computer-use-mcp/helper/process";
import { ClientIdentityStore } from "./server/paseo/identity-store";
import { addComputerUseServer } from "./server/paseo/inject";
import { registerComputerUseRpcHandlers } from "./server/paseo/rpc-handlers";

/**
 * Names the plugin state dir after the Paseo home the daemon uses. The host
 * resolves `PASEO_HOME` (default `~/.paseo`) to an absolute path, so the same
 * home must give the same key however it was spelled or launched: unset or
 * `~/.paseo`, a trailing slash, or a symlink to it. The listen address is not
 * part of the key, so a change of launch mode keeps the same identity map.
 */
export function computeHomeKey(
  env: NodeJS.ProcessEnv = process.env,
  homeDir: string = homedir(),
): string {
  const raw = env.PASEO_HOME ?? "~/.paseo";
  const expanded =
    raw === "~" ? homeDir : raw.startsWith("~/") ? path.join(homeDir, raw.slice(2)) : raw;
  const resolved = path.resolve(expanded);
  let canonical = resolved;
  try {
    canonical = realpathSync(resolved);
  } catch {
    // The home may not exist yet on a first start; the resolved path still
    // names it.
  }
  return createHash("sha256").update(canonical).digest("hex").slice(0, 12);
}

/**
 * The key that earlier builds used for the state dir. It hashed the raw
 * `PASEO_HOME` text, or the listen address when that was unset.
 */
export function computeLegacyHomeKey(env: NodeJS.ProcessEnv = process.env): string {
  const homeSource = env.PASEO_HOME ?? `listen:${env.PASEO_LISTEN ?? "default"}`;
  return createHash("sha256").update(homeSource).digest("hex").slice(0, 12);
}

const IDENTITY_MAP_FILE = "client-bindings.json";

/**
 * Copies the client -> agent map from the state dir of an earlier build into
 * the current one, once. Without it, agents created before an upgrade lose
 * their binding, so their turn ends could not release the computer. The copy
 * happens only while the current dir has no map, so later bindings are never
 * overwritten. The old file stays in place so an older build still works.
 */
export function migrateLegacyIdentityMap(
  stateRoot: string,
  stateDir: string,
  legacyHomeKey: string,
): boolean {
  const legacyDir = path.join(stateRoot, legacyHomeKey);
  if (path.resolve(legacyDir) === path.resolve(stateDir)) return false;
  const target = path.join(stateDir, IDENTITY_MAP_FILE);
  const source = path.join(legacyDir, IDENTITY_MAP_FILE);
  if (existsSync(target) || !existsSync(source)) return false;
  try {
    copyFileSync(source, target, constants.COPYFILE_EXCL);
    return true;
  } catch {
    // Another daemon copied it first, or the old file is unreadable; the
    // store then starts from what is on disk.
    return false;
  }
}

function resolveStatePaths(): {
  homeKey: string;
  stateDir: string;
  socketPath: string;
} {
  const homeKey = computeHomeKey();
  const stateRoot = path.join(homedir(), ".local", "state", "paseo-computer-use");
  const stateDir = path.join(stateRoot, homeKey);
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  migrateLegacyIdentityMap(stateRoot, stateDir, computeLegacyHomeKey());

  const candidateSocket = path.join(stateDir, "mcp.sock");
  const socketPath =
    Buffer.byteLength(candidateSocket, "utf8") < 100
      ? candidateSocket
      : path.join("/tmp", `paseo-cu-${process.getuid?.() ?? 0}-${homeKey}.sock`);

  return { homeKey, stateDir, socketPath };
}

export default function contribute(server: PluginServerContext) {
  const settingsHandle = server.registerSettings(computerUseSettings);
  const { stateDir, socketPath } = resolveStatePaths();
  const identityStore = new ClientIdentityStore(stateDir);

  // The host only notifies subscribers on change, so read once for the initial
  // value. An invalid stored value keeps the last good settings (defaults at start).
  let currentSettings: ComputerUseSettingsValues = computerUseSettingsSchema.parse({});
  let receivedSettingsChange = false;
  const applySettings = (state: PluginSettingsState<typeof computerUseSettingsSchema>) => {
    if (state.status === "ready") currentSettings = state.values;
  };
  const unsubscribeSettings = settingsHandle.subscribe((state) => {
    receivedSettingsChange = true;
    applySettings(state);
  });
  // One shared promise for the first read. agent.create awaits it so an agent
  // created right after startup sees the stored settings, not the defaults.
  const initialSettingsLoad = settingsHandle
    .read()
    .then((state) => {
      // A change that arrived while the first read was in flight is newer.
      if (!receivedSettingsChange) applySettings(state);
    })
    .catch(() => {});

  let helperBuildState: "idle" | "building" | "ready" | "failed" = "idle";
  let helperBuildError: string | null = null;
  let compiledBinaryPath: string | undefined;

  const initialShim = installMcpShim({ stateDir, socketPath });
  let shimPath = initialShim.shimPath;

  if (process.platform === "darwin") {
    helperBuildState = "building";
    void buildHelperBinary()
      .then((binPath) => {
        compiledBinaryPath = binPath;
        helperBuildState = "ready";
        helperBuildError = null;
        const updated = installMcpShim({
          stateDir,
          socketPath,
          compiledBinaryPath: binPath,
        });
        shimPath = updated.shimPath;
      })
      .catch((err: unknown) => {
        helperBuildState = "failed";
        helperBuildError = err instanceof Error ? err.message : String(err);
      });
  } else {
    helperBuildState = "failed";
    helperBuildError = `Unsupported platform: ${process.platform}`;
  }

  const helperProcess = new HelperProcess({
    resolveBinary: async () => {
      if (compiledBinaryPath) return compiledBinaryPath;
      try {
        const bin = await buildHelperBinary();
        compiledBinaryPath = bin;
        helperBuildState = "ready";
        helperBuildError = null;
        return bin;
      } catch (err: unknown) {
        // Record the failure so the status RPC can show it; the helper start
        // still fails for this call.
        helperBuildState = "failed";
        helperBuildError = err instanceof Error ? err.message : String(err);
        throw err;
      }
    },
  });

  const service = createComputerUseService({
    helperPort: helperProcess,
    socketPath,
    platformSupported: process.platform === "darwin",
    getSettings: () => currentSettings,
    getHelperBuildStatus: () => ({
      state: helperBuildState,
      error: helperBuildError,
    }),
    resolveAgentId: (callerId) => identityStore.resolveAgentId(callerId),
  });

  let socketError: string | null = null;
  void service.start().catch((err: unknown) => {
    socketError = err instanceof Error ? err.message : String(err);
  });
  registerComputerUseRpcHandlers(server, service, { getSocketError: () => socketError });

  server.before("agent.create", async ({ request }) => {
    await initialSettingsLoad;
    try {
      const clientId = randomUUID();
      return addComputerUseServer(request, currentSettings, {
        clientId,
        shimPath,
        socketPath,
      });
    } catch {
      return request;
    }
  });

  // The create hook has no agent id yet, so the client id it put into the
  // agent's env is bound here, the first hook that sees both. Resume opens
  // carry no env, so they rely on the persisted map instead.
  server.before("agent.session_open", ({ request }) => {
    const clientId = request.env?.PASEO_CU_CLIENT;
    if (clientId && request.agentId) {
      identityStore.bind(clientId, request.agentId, request.provider);
    }
    return undefined;
  });

  server.on("agent.created", (event) => {
    identityStore.confirm(event.agent.id);
  });

  // Every turn end releases the computer and clears an Escape stop for that
  // agent. A canceled turn (Paseo's Stop button) also cancels the running
  // command.
  server.on("agent.turn_ended", async (event) => {
    await service.onAgentTurnEnded(event.agent.id, event.outcome.kind);
  });

  // The daemon closes every agent when it shuts down, so a close only frees
  // runtime state. The client -> agent map must survive that restart.
  server.on("agent.closed", async (event) => {
    await service.onAgentClosed(event.agent.id);
  });

  // The binding stays after archive: the host can unarchive an agent without
  // any plugin hook, and the resumed agent reconnects with the same client
  // id. Without the binding, its turn ends could not release the computer or
  // clear its Escape stop.
  server.on("agent.archived", async (event) => {
    await service.onAgentClosed(event.agent.id);
  });

  return () => {
    void unsubscribeSettings();
    void service.stop();
    void helperProcess.stop();
  };
}
