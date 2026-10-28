import { SUPPORTED_PROVIDERS } from "../../shared/settings";
import { ElementIds } from "./ax/element-ids";
import type { HelperPort } from "./contract/helper-port";
import { createHelperDriver } from "./facade/helper-driver";
import {
  ComputerUseMcpServer,
  ComputerUseSocketListener,
  type SocketHelloPayload,
} from "./mcp";
import {
  AbortMonitor,
  type AuditEntry,
  AuditLog,
  ControlLock,
  type PolicyEngineConfig,
} from "./policy";
import { ActionSettler, type ActionSettlerClock } from "./runtime/action-settler";

export * from "./ax/accessibility-tree";
export * from "./ax/element-ids";
export * from "./contract/errors";
export * from "./contract/helper-port";
export * from "./contract/helper-protocol";
export * from "./contract/results";
export * from "./facade";
export * from "./mcp";
export * from "./policy";
export * from "./runtime/action-settler";

/**
 * The name the virtual pointer shows for the agent in control: the display
 * name of the provider the shim reported in its hello, or "Agent" for a
 * provider this plugin does not list.
 */
export function overlayLabelForProvider(provider: string | undefined): string {
  const id = provider?.trim().toLowerCase();
  return SUPPORTED_PROVIDERS.find((entry) => entry.id === id)?.label ?? "Agent";
}
export * from "./runtime/uint8";

export interface ComputerUseRuntimeSettings {
  enabled: boolean;
  extraBlockedBundleIds: string[];
  screenshots: "auto" | "always" | "never";
  allowBrowserApps: boolean;
}

export interface ComputerUseServiceStatus {
  enabled: boolean;
  platformSupported: boolean;
  helperBuildState: "idle" | "building" | "ready" | "failed";
  helperBuildError: string | null;
  axTrusted: boolean;
  screenCaptureGranted: boolean;
  abortTapAvailable: boolean;
  inputSourceId: string | null;
  isInputMethod: boolean;
  activeOwner: string | null;
  activeAgentId: string | null;
  auditEntries: AuditEntry[];
}

export interface CreateComputerUseServiceDeps {
  helperPort: HelperPort;
  socketPath?: string;
  platformSupported?: boolean;
  idleLockTimeoutMs?: number;
  postActionSleepMs?: number;
  // The clock wait_for polls with. Tests pass a fake one.
  waitClock?: ActionSettlerClock;
  getSettings?: () => Partial<ComputerUseRuntimeSettings>;
  getHelperBuildStatus?: () => {
    state: "idle" | "building" | "ready" | "failed";
    error: string | null;
  };
  onStatusChanged?: () => void;
  // Maps the client id that the plugin put into the agent's MCP config to
  // the host agent id. Codex does not pass PASEO_AGENT_ID to the MCP shim,
  // so this map is the only reliable way to name the agent behind a socket.
  resolveAgentId?: (clientId: string) => string | null;
}

export type AgentTurnOutcome = "completed" | "failed" | "canceled";

export interface ComputerUseService {
  readonly policy: PolicyEngineConfig;
  readonly controlLock: ControlLock;
  readonly abortMonitor: AbortMonitor;
  readonly auditLog: AuditLog;
  readonly socketListener: ComputerUseSocketListener | null;
  start(): Promise<void>;
  stop(): Promise<void>;
  getSocketPath(): string | null;
  getStatus(): Promise<ComputerUseServiceStatus>;
  stopControl(): Promise<{ stopped: boolean }>;
  getAuditLog(): AuditEntry[];
  onAgentClosed(agentId: string): Promise<void>;
  onAgentTurnEnded(agentId: string, outcome?: AgentTurnOutcome): Promise<void>;
  createMcpServer(hello: SocketHelloPayload): ComputerUseMcpServer;
}

export function createComputerUseService(
  deps: CreateComputerUseServiceDeps,
): ComputerUseService {
  const getSettings = (): ComputerUseRuntimeSettings => {
    const raw = deps.getSettings?.() ?? {};
    return {
      enabled: raw.enabled ?? false,
      extraBlockedBundleIds: raw.extraBlockedBundleIds ?? [],
      screenshots: raw.screenshots ?? "auto",
      allowBrowserApps: raw.allowBrowserApps ?? false,
    };
  };

  interface CallerSession {
    driver: ReturnType<typeof createHelperDriver>;
    // True when the caller could not be matched to a host agent when it
    // connected, so it is keyed by its raw client id. A raw client id never
    // equals the agent id in a turn-end hook, so no turn end can clear its
    // Escape stop; the idle clear below does.
    unmapped: boolean;
  }

  const sessions = new Map<string, CallerSession>();

  const idleTimeoutMs = deps.idleLockTimeoutMs ?? 60_000;

  // A binding that appeared since the caller connected makes it a known
  // agent again, whose own turn end clears its stop.
  const isUnmappedCaller = (callerId: string): boolean =>
    sessions.get(callerId)?.unmapped === true &&
    (deps.resolveAgentId?.(callerId) ?? null) === null;

  // An Escape stop of a caller that matches no host agent cannot be tied to
  // any turn end: clearing it on another agent's turn end would let the
  // stopped agent act again in the same turn. It is cleared only after the
  // caller has left Computer Use alone for the lock's idle timeout (every
  // refused call starts the wait again), or when the plugin restarts.
  const unmappedStopTimers = new Map<string, ReturnType<typeof setTimeout>>();

  const scheduleUnmappedStopClear = (callerId: string): void => {
    if (idleTimeoutMs <= 0 || !isUnmappedCaller(callerId)) {
      return;
    }
    const previous = unmappedStopTimers.get(callerId);
    if (previous) {
      clearTimeout(previous);
    }
    const timer = setTimeout(() => {
      unmappedStopTimers.delete(callerId);
      if (isUnmappedCaller(callerId)) {
        abortMonitor.clearCallerAbort(callerId);
        deps.onStatusChanged?.();
      }
    }, idleTimeoutMs);
    timer.unref?.();
    unmappedStopTimers.set(callerId, timer);
  };

  const clearUnmappedStopTimers = (): void => {
    for (const timer of unmappedStopTimers.values()) {
      clearTimeout(timer);
    }
    unmappedStopTimers.clear();
  };

  // The helper's overlay (virtual pointer and window halo) is shown only
  // while some caller owns the computer. Every path that clears the owner
  // (turn end, closed connection, idle timeout, Stop, agent close, Escape,
  // a failed arm) goes through the lock, so the lock's owner change is the
  // one place that hides it. A helper that exited has no overlay; asking it
  // to hide would only start a new helper. The flag is set again when the
  // owner arms the tap on a live helper, which every action does first.
  let overlayMayBeShown = false;
  const unsubscribeOverlayExit = deps.helperPort.onEvent((event) => {
    if (event.event === "exited") {
      overlayMayBeShown = false;
    }
  });

  const hideOverlay = (): void => {
    if (!overlayMayBeShown) {
      return;
    }
    overlayMayBeShown = false;
    deps.helperPort.request("end_turn", {}).catch(() => {
      // A helper that is stopping or gone has no overlay left to hide.
    });
  };

  const controlLock = new ControlLock({
    helperPort: deps.helperPort,
    idleTimeoutMs,
    onOwnerChanged: (owner) => {
      if (owner.callerId === null) {
        hideOverlay();
      } else {
        overlayMayBeShown = true;
      }
      deps.onStatusChanged?.();
    },
    onAbortTapArmed: () => {
      overlayMayBeShown = true;
    },
  });

  const abortMonitor = new AbortMonitor({
    helperPort: deps.helperPort,
    controlLock,
    onAbort: ({ callerId }) => {
      // The stopped caller starts its idle wait again; other stopped callers
      // keep the wait they already have.
      for (const stopped of abortMonitor.abortedCallerIds()) {
        if (stopped === callerId || !unmappedStopTimers.has(stopped)) {
          scheduleUnmappedStopClear(stopped);
        }
      }
      deps.onStatusChanged?.();
    },
    onRefused: scheduleUnmappedStopClear,
  });

  const auditLog = new AuditLog(200);

  const policy: PolicyEngineConfig = {
    controlLock,
    abortMonitor,
    auditLog,
    getExtraBlockedBundleIds: () => getSettings().extraBlockedBundleIds,
    isEnabled: () => getSettings().enabled,
    allowBrowserApps: () => getSettings().allowBrowserApps,
  };

  // The plugin's own client -> agent map wins over the agent id in the
  // hello: the map is written by the host hooks, while the hello comes from
  // the agent's environment, which some providers do not pass through.
  const agentIdOf = (hello: SocketHelloPayload): string | null =>
    deps.resolveAgentId?.(hello.clientId) ?? (hello.agentId?.trim() || null);

  // The lock, the stop state, and the sessions are keyed by the agent id, so
  // every connection of one agent counts as the same owner.
  const callerIdOf = (hello: SocketHelloPayload): string =>
    agentIdOf(hello) ?? (hello.clientId.trim() || "default");

  const belongsToAgent = (callerId: string, agentId: string): boolean =>
    callerId === agentId || deps.resolveAgentId?.(callerId) === agentId;

  const getOrCreateSession = (hello: SocketHelloPayload): {
    callerId: string;
    session: CallerSession;
  } => {
    const callerId = callerIdOf(hello);
    const existing = sessions.get(callerId);
    if (existing) {
      return { callerId, session: existing };
    }
    const driver = createHelperDriver({
      helperPort: deps.helperPort,
      policy,
      elementIds: new ElementIds(),
      actionSettler: new ActionSettler(deps.postActionSleepMs ?? 100),
      overlayLabel: overlayLabelForProvider(hello.provider),
      getCallerContext: () => ({
        callerId,
        agentId: agentIdOf(hello),
      }),
    });
    const session: CallerSession = { driver, unmapped: agentIdOf(hello) === null };
    sessions.set(callerId, session);
    return { callerId, session };
  };

  const getStatus = async (): Promise<ComputerUseServiceStatus> => {
    const settings = getSettings();
    const buildStatus = deps.getHelperBuildStatus?.() ?? {
      state: "ready" as const,
      error: null,
    };
    const platformSupported =
      deps.platformSupported ?? process.platform === "darwin";

    let axTrusted = false;
    let screenCaptureGranted = false;
    let abortTapAvailable = false;
    let inputSourceId: string | null = null;
    let isInputMethod = false;

    if (platformSupported && buildStatus.state === "ready") {
      try {
        const helperStatus = await deps.helperPort.request("status", {});
        axTrusted = helperStatus.axTrusted;
        screenCaptureGranted = helperStatus.screenCaptureGranted;
        abortTapAvailable = helperStatus.abortTapAvailable;
        inputSourceId = helperStatus.inputSourceId || null;
        isInputMethod = helperStatus.isInputMethod;
      } catch {
        // Helper not running or unreachable; report default false flags
      }
    }

    const owner = controlLock.getActiveOwner();

    return {
      enabled: settings.enabled,
      platformSupported,
      helperBuildState: buildStatus.state,
      helperBuildError: buildStatus.error,
      axTrusted,
      screenCaptureGranted,
      abortTapAvailable,
      inputSourceId,
      isInputMethod,
      activeOwner: owner.callerId,
      activeAgentId: owner.agentId ?? owner.callerId,
      auditEntries: auditLog.list(),
    };
  };

  const createMcpServer = (hello: SocketHelloPayload): ComputerUseMcpServer => {
    const { session } = getOrCreateSession(hello);
    return new ComputerUseMcpServer({
      tools: {
        driver: session.driver,
        getStatus,
        getScreenshotMode: () => getSettings().screenshots,
        ...(deps.waitClock ? { waitClock: deps.waitClock } : {}),
      },
    });
  };

  // A closed connection cannot finish its work, so its running command is
  // cancelled and it must not keep the computer (and the Escape tap) until
  // the idle timeout. The stop is not sticky: a provider that restarts its
  // MCP server reconnects as the same caller and must be able to act.
  const onClientClosed = async (hello: SocketHelloPayload): Promise<void> => {
    const callerId = callerIdOf(hello);
    if (abortMonitor.inFlightCallerIds().includes(callerId)) {
      await abortMonitor.triggerAbort("connection_closed", callerId, { sticky: false });
    }
    if (controlLock.isOwnedBy(callerId)) {
      await controlLock.release(callerId);
    }
  };

  const socketListener = deps.socketPath
    ? new ComputerUseSocketListener({
        socketPath: deps.socketPath,
        createServerForClient: createMcpServer,
        onClientClosed,
      })
    : null;

  return {
    policy,
    controlLock,
    abortMonitor,
    auditLog,
    socketListener,

    async start(): Promise<void> {
      if (socketListener) {
        await socketListener.start();
      }
    },

    async stop(): Promise<void> {
      abortMonitor.dispose();
      clearUnmappedStopTimers();
      if (socketListener) {
        await socketListener.stop();
      }
      await controlLock.release();
      controlLock.dispose();
      unsubscribeOverlayExit();
      sessions.clear();
    },

    getSocketPath(): string | null {
      return socketListener?.getSocketPath() ?? null;
    },

    getStatus,

    async stopControl(): Promise<{ stopped: boolean }> {
      const owner = controlLock.getActiveOwner();
      // The abort releases the lock, and the release hides the overlay.
      await abortMonitor.triggerAbort(
        "user_intervened",
        owner.callerId ?? undefined,
      );
      return { stopped: true };
    },

    getAuditLog(): AuditEntry[] {
      return auditLog.list();
    },

    // Sessions, stops, and the lock are keyed by caller id. A caller that
    // connected before its client id was bound to the agent keeps its raw
    // client id as key, so every key that belongs to the agent is matched.
    async onAgentClosed(agentId: string): Promise<void> {
      for (const callerId of abortMonitor.abortedCallerIds()) {
        if (belongsToAgent(callerId, agentId)) {
          abortMonitor.clearCallerAbort(callerId);
        }
      }
      for (const callerId of sessions.keys()) {
        if (belongsToAgent(callerId, agentId)) {
          sessions.delete(callerId);
        }
      }
      const owner = controlLock.getActiveOwner().callerId;
      if (owner !== null && belongsToAgent(owner, agentId)) {
        await controlLock.release(owner);
      }
    },

    // Every host turn end (completed, failed, or canceled) gives the computer
    // back and clears the agent's own Escape stop. The next mutating call
    // takes the lock again and re-arms the tap.
    async onAgentTurnEnded(agentId: string, outcome?: AgentTurnOutcome): Promise<void> {
      const owner = controlLock.getActiveOwner();
      const ownedByAgent =
        owner.callerId !== null &&
        (owner.agentId === agentId || belongsToAgent(owner.callerId, agentId));

      // A canceled turn is Paseo's Stop button: cancel the helper command
      // that is still running for this agent, so the tool returns
      // aborted_by_user instead of finishing the action.
      if (outcome === "canceled") {
        const targets = new Set(
          abortMonitor.inFlightCallerIds().filter((callerId) => belongsToAgent(callerId, agentId)),
        );
        // Fallback when the owner could not be matched to any host agent:
        // there is only one owner, so a canceled turn from any agent stops
        // it. The cost is that Stop on an unrelated agent can interrupt this
        // action; that is accepted because it fails toward stopping. An owner
        // that is known to be a different agent is not touched.
        const ownerUnmapped =
          owner.callerId !== null &&
          owner.agentId === null &&
          (deps.resolveAgentId?.(owner.callerId) ?? null) === null;
        if (owner.callerId !== null && (ownedByAgent || ownerUnmapped)) {
          targets.add(owner.callerId);
        }
        // Not sticky: the turn is already over, so only the running work is
        // cancelled. The next turn may use the computer again.
        for (const callerId of targets) {
          await abortMonitor.triggerAbort("stop_button", callerId, { sticky: false });
        }
      }

      // Only the agent's own turn end clears its Escape stop. A caller that
      // matches no host agent waits for the idle clear instead.
      for (const callerId of abortMonitor.abortedCallerIds()) {
        if (belongsToAgent(callerId, agentId)) {
          abortMonitor.clearCallerAbort(callerId);
        }
      }
      if (ownedByAgent && owner.callerId !== null) {
        await controlLock.release(owner.callerId);
      }
    },

    createMcpServer,
  };
}
