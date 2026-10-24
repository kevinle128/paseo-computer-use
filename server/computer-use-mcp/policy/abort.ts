import {
  ComputerUseError,
  type HelperErrorCode,
  PHYSICAL_ESCAPE_STOP_MESSAGE,
  USER_INTERVENED_STOP_MESSAGE,
} from "../contract/errors";
import type { HelperPort } from "../contract/helper-port";
import type { HelperUnsolicitedEvent } from "../contract/helper-protocol";
import type { ControlLock } from "./lock";

// Paseo's Stop button cancels the agent's turn. The agent never sees this
// message unless a tool call was still running, but it must still say why.
export const STOP_BUTTON_MESSAGE =
  "Computer Use was stopped because the user pressed Stop in Paseo. Stop your work and do not call further Computer Use tools in this turn.";

// Used when the agent's connection to Computer Use closed during a command.
// Nobody pressed anything, so the audit trail must not say the user did.
export const CONNECTION_CLOSED_MESSAGE =
  "Computer Use stopped this action because the agent's connection to Computer Use closed.";

export type AbortReason = "escape_key" | "user_intervened" | "stop_button" | "connection_closed";

export interface AbortMonitorOptions {
  helperPort?: HelperPort;
  controlLock: ControlLock;
  onAbort?: (info: {
    callerId: string | null;
    reason: AbortReason;
    message: string;
  }) => void;
  // Called each time a stopped caller is refused, so the owner of the stop
  // can tell a caller that keeps trying apart from one that went quiet.
  onRefused?: (callerId: string) => void;
}

interface AbortedCallerState {
  reason: AbortReason;
  message: string;
  code: HelperErrorCode;
}

const STOP_MESSAGES: Record<AbortReason, string> = {
  escape_key: PHYSICAL_ESCAPE_STOP_MESSAGE,
  user_intervened: USER_INTERVENED_STOP_MESSAGE,
  stop_button: STOP_BUTTON_MESSAGE,
  connection_closed: CONNECTION_CLOSED_MESSAGE,
};

export class AbortMonitor {
  private readonly controlLock: ControlLock;
  private readonly onAbort?: AbortMonitorOptions["onAbort"];
  private readonly onRefused?: AbortMonitorOptions["onRefused"];
  private readonly inFlightControllers = new Map<string, Set<AbortController>>();
  private readonly abortedCallers = new Map<string, AbortedCallerState>();
  private unsubscribeHelper?: () => void;

  constructor(options: AbortMonitorOptions) {
    this.controlLock = options.controlLock;
    this.onAbort = options.onAbort;
    this.onRefused = options.onRefused;

    if (options.helperPort) {
      this.attachHelper(options.helperPort);
    }
  }

  attachHelper(helperPort: HelperPort): void {
    this.unsubscribeHelper?.();
    this.unsubscribeHelper = helperPort.onEvent((event: HelperUnsolicitedEvent) => {
      if (event.event === "abort") {
        void this.triggerAbort(event.reason);
      }
    });
  }

  dispose(): void {
    this.unsubscribeHelper?.();
    this.unsubscribeHelper = undefined;
  }

  registerInFlight(callerId: string): {
    controller: AbortController;
    cleanup: () => void;
  } {
    const controller = new AbortController();
    let set = this.inFlightControllers.get(callerId);
    if (!set) {
      set = new Set<AbortController>();
      this.inFlightControllers.set(callerId, set);
    }
    set.add(controller);

    return {
      controller,
      cleanup: () => {
        const currentSet = this.inFlightControllers.get(callerId);
        if (currentSet) {
          currentSet.delete(controller);
          if (currentSet.size === 0) {
            this.inFlightControllers.delete(callerId);
          }
        }
      },
    };
  }

  // A stop holds until the host reports the turn ended. Nothing an agent
  // sends (a new turn id, another tool call) can clear it.
  assertNotAborted(callerId: string): void {
    const state = this.abortedCallers.get(callerId);
    if (!state) {
      return;
    }
    this.onRefused?.(callerId);
    throw new ComputerUseError({
      code: state.code,
      message: state.message,
    });
  }

  // Only the host turn-end and agent-close hooks, and the idle clear of a
  // caller that matches no host agent, call this.
  clearCallerAbort(callerId: string): void {
    this.abortedCallers.delete(callerId);
  }

  abortedCallerIds(): string[] {
    return [...this.abortedCallers.keys()];
  }

  inFlightCallerIds(): string[] {
    return [...this.inFlightControllers.keys()];
  }

  // A sticky stop (Escape, takeover) refuses the caller's later calls until
  // the host reports the turn ended. A non-sticky stop is used when the turn
  // or the connection has already ended: it only cancels the work in flight.
  async triggerAbort(
    reason: AbortReason,
    targetCallerId?: string,
    options: { sticky?: boolean } = {},
  ): Promise<void> {
    const sticky = options.sticky ?? true;
    const activeOwner = this.controlLock.getActiveOwner();
    const callerId = targetCallerId ?? activeOwner.callerId;
    const message = STOP_MESSAGES[reason];
    const code =
      reason === "user_intervened"
        ? "user_intervened"
        : "aborted_by_user";

    const abortError = new ComputerUseError({
      code,
      message,
    });

    if (callerId) {
      if (sticky) this.abortedCallers.set(callerId, { reason, message, code });

      const controllers = this.inFlightControllers.get(callerId);
      if (controllers) {
        for (const controller of controllers) {
          controller.abort(abortError);
        }
        controllers.clear();
      }
    } else {
      for (const [cid, controllers] of this.inFlightControllers.entries()) {
        if (sticky) this.abortedCallers.set(cid, { reason, message, code });
        for (const controller of controllers) {
          controller.abort(abortError);
        }
        controllers.clear();
      }
    }

    await this.controlLock.release(callerId ?? undefined);
    this.onAbort?.({ callerId: callerId ?? null, reason, message });
  }
}
