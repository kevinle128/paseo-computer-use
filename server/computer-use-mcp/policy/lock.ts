import { ComputerUseToolError } from "../contract/errors";
import type { HelperPort } from "../contract/helper-port";

// The Escape tap is the user's stop key. Acting without it would leave no way
// to stop an agent from the keyboard, so mutation is refused instead.
export const ABORT_TAP_PERMISSION_MESSAGE =
  "permission_missing: Computer Use could not arm the Escape stop key, so it will not act on apps. Grant Accessibility permission to the app that runs Paseo in System Settings > Privacy & Security > Accessibility (and Input Monitoring if macOS asks), then try again.";

// Returned when Stop, a turn end, or a closed connection took the computer
// back while this call was still arming the Escape tap.
export const LOCK_LOST_MESSAGE =
  "aborted_by_user: The computer was taken back (the user pressed Stop or the turn ended) before this action started. Stop your work and do not call further Computer Use tools in this turn.";

export interface ControlLockOptions {
  helperPort?: HelperPort;
  idleTimeoutMs?: number;
  onOwnerChanged?: (owner: { callerId: string | null; agentId: string | null }) => void;
  // Called when the helper confirms the Escape tap is armed. The owner is
  // about to act on that helper process, which may be a new one after a
  // restart while the same owner kept the lock.
  onAbortTapArmed?: () => void;
}

export class ControlLock {
  private readonly helperPort?: HelperPort;
  private readonly idleTimeoutMs: number;
  private readonly onOwnerChanged?: (owner: {
    callerId: string | null;
    agentId: string | null;
  }) => void;

  private activeCallerId: string | null = null;
  private activeAgentId: string | null = null;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private abortTapArmed = false;
  // One arm request at a time, so a second acquire waits for the real answer
  // instead of assuming the tap is armed.
  private arming: Promise<boolean> | null = null;
  // Acquires run one after another, so an acquire never sees the half-done
  // state of another acquire that is still arming the tap.
  private acquireChain: Promise<void> = Promise.resolve();
  // Bumped on every release. An acquire compares it after the arm reply to
  // find out that a release ran while it waited.
  private releaseGeneration = 0;
  private readonly unsubscribeHelper?: () => void;
  private readonly onAbortTapArmed?: () => void;

  constructor(options: ControlLockOptions = {}) {
    this.helperPort = options.helperPort;
    this.idleTimeoutMs = options.idleTimeoutMs ?? 60_000;
    this.onOwnerChanged = options.onOwnerChanged;
    this.onAbortTapArmed = options.onAbortTapArmed;
    // A restarted helper starts with the tap disarmed; forget the old state
    // so the next mutating call arms the new process.
    this.unsubscribeHelper = this.helperPort?.onEvent((event) => {
      if (event.event === "exited") {
        this.abortTapArmed = false;
      }
    });
  }

  dispose(): void {
    this.unsubscribeHelper?.();
  }

  isAbortTapArmed(): boolean {
    return this.abortTapArmed;
  }

  getActiveOwner(): { callerId: string | null; agentId: string | null } {
    return {
      callerId: this.activeCallerId,
      agentId: this.activeAgentId,
    };
  }

  isOwnedBy(callerId: string): boolean {
    return this.activeCallerId === callerId;
  }

  // Only mutating tools call this. Reading the screen does not take the
  // computer, so it neither blocks nor is blocked by the owner.
  acquire(callerId: string, agentId?: string | null): Promise<void> {
    const run = this.acquireChain.then(() => this.acquireNow(callerId, agentId ?? null));
    this.acquireChain = run.catch(() => {});
    return run;
  }

  private async acquireNow(callerId: string, agentId: string | null): Promise<void> {
    if (this.activeCallerId !== null && this.activeCallerId !== callerId) {
      // A busy lock is a refusal, not a user takeover, so it gets its own code.
      throw new ComputerUseToolError(
        "computer_busy",
        `computer_busy: Computer Use is currently controlled by another session (${this.activeCallerId}).`,
      );
    }

    const wasUnowned = this.activeCallerId === null;
    this.activeCallerId = callerId;
    // Null when the caller could not be matched to a host agent. The Stop
    // fallback needs to tell such an owner apart from a known agent.
    this.activeAgentId = agentId;
    this.scheduleIdleRelease();
    const generation = this.releaseGeneration;

    if (wasUnowned) {
      this.onOwnerChanged?.(this.getActiveOwner());
    }

    // Checked on every acquire, not only when the owner changes: a helper
    // restart disarms the tap while the same agent keeps the lock.
    const armed = await this.armAbortTap();

    // A missing permission is reported first, even when a release also ran
    // during the arm: otherwise the agent reads "stopped by the user" and
    // never learns that the user must grant a permission.
    if (!armed) {
      await this.release(callerId);
      throw new ComputerUseToolError("permission_missing", ABORT_TAP_PERMISSION_MESSAGE);
    }

    // A release that ran during the arm saw the tap still unarmed and sent no
    // disarm. Undo the arm here and refuse, so the action never runs without
    // an owner and the tap never stays armed for nobody.
    if (this.releaseGeneration !== generation) {
      if (this.activeCallerId === null) {
        await this.disarmAbortTap();
      }
      throw new ComputerUseToolError("aborted_by_user", LOCK_LOST_MESSAGE);
    }
  }

  touch(callerId: string): void {
    if (this.activeCallerId === callerId) {
      this.scheduleIdleRelease();
    }
  }

  async release(callerId?: string): Promise<boolean> {
    if (this.activeCallerId === null) {
      return false;
    }
    if (callerId !== undefined && this.activeCallerId !== callerId) {
      return false;
    }

    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }

    this.activeCallerId = null;
    this.activeAgentId = null;
    this.releaseGeneration += 1;
    this.onOwnerChanged?.(this.getActiveOwner());
    await this.disarmAbortTap();
    return true;
  }

  private scheduleIdleRelease(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
    }
    if (this.idleTimeoutMs <= 0) {
      return;
    }
    this.idleTimer = setTimeout(() => {
      void this.release();
    }, this.idleTimeoutMs);
    if (typeof this.idleTimer === "object" && "unref" in this.idleTimer) {
      this.idleTimer.unref();
    }
  }

  private async armAbortTap(): Promise<boolean> {
    if (!this.helperPort || this.abortTapArmed) {
      return true;
    }
    if (!this.arming) {
      const helperPort = this.helperPort;
      this.arming = (async () => {
        try {
          const result = await helperPort.request("abort_tap.arm", {});
          this.abortTapArmed = result.armed === true;
          if (this.abortTapArmed) {
            this.onAbortTapArmed?.();
          }
        } catch {
          this.abortTapArmed = false;
        }
        return this.abortTapArmed;
      })().finally(() => {
        this.arming = null;
      });
    }
    return this.arming;
  }

  private async disarmAbortTap(): Promise<void> {
    if (!this.helperPort || !this.abortTapArmed) {
      this.abortTapArmed = false;
      return;
    }
    this.abortTapArmed = false;
    try {
      await this.helperPort.request("abort_tap.disarm", {});
    } catch {
      // Ignore disarm failures if helper exited
    }
  }
}
