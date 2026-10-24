import {
  ComputerUseError,
  ComputerUseToolError,
} from "../contract/errors";
import { AbortMonitor } from "./abort";
import { AuditLog } from "./audit";
import { assertAppNotBlocked } from "./deny-list";
import { ControlLock } from "./lock";

export * from "./abort";
export * from "./audit";
export * from "./deny-list";
export * from "./lock";

export interface PolicyExecutionContext {
  callerId: string;
  agentId?: string | null;
  turnId?: string;
  toolName: string;
  // Mutating tools take the one-owner control lock and need the Escape tap
  // armed. Read tools take neither.
  mutating: boolean;
  app?: string;
  displayName?: string;
  textLength?: number;
}

export interface PolicyEngineConfig {
  controlLock: ControlLock;
  abortMonitor: AbortMonitor;
  auditLog: AuditLog;
  getExtraBlockedBundleIds?: () => Iterable<string>;
  // Read on every call so turning the setting off stops agents that were
  // created while it was on.
  isEnabled?: () => boolean;
}

export async function withComputerUsePolicy<TInput extends { app?: string }, TResult>(
  engine: PolicyEngineConfig,
  context: PolicyExecutionContext,
  input: TInput,
  action: (resolvedInput: TInput, options: { signal: AbortSignal }) => Promise<TResult>,
): Promise<TResult> {
  const startMs = performance.now();
  const app = (input?.app ?? context.app)?.trim();
  let status: "completed" | "cancelled" | "failed" = "completed";

  if (engine.isEnabled && !engine.isEnabled()) {
    throw new ComputerUseToolError(
      "computer_use_disabled",
      "Computer Use is turned off in Paseo settings. Ask the user to enable it.",
    );
  }

  engine.abortMonitor.assertNotAborted(context.callerId);

  if (app) {
    assertAppNotBlocked(app, engine.getExtraBlockedBundleIds?.());
  }

  if (context.mutating) {
    await engine.controlLock.acquire(context.callerId, context.agentId);
  }

  const runOnce = async (currentInput: TInput): Promise<TResult> => {
    engine.abortMonitor.assertNotAborted(context.callerId);
    const { controller, cleanup } = engine.abortMonitor.registerInFlight(
      context.callerId,
    );
    try {
      const onAbortPromise = new Promise<never>((_, reject) => {
        if (controller.signal.aborted) {
          reject(controller.signal.reason);
          return;
        }
        controller.signal.addEventListener(
          "abort",
          () => {
            reject(controller.signal.reason);
          },
          { once: true },
        );
      });
      return await Promise.race([
        action(currentInput, { signal: controller.signal }),
        onAbortPromise,
      ]);
    } finally {
      cleanup();
    }
  };

  try {
    const result = await runOnce(input);
    if (context.mutating) {
      engine.controlLock.touch(context.callerId);
    }
    return result;
  } catch (error) {
    if (
      error instanceof ComputerUseError &&
      (error.code === "aborted_by_user" ||
        error.code === "user_intervened")
    ) {
      status = "cancelled";
    } else {
      status = "failed";
    }
    throw error;
  } finally {
    engine.auditLog.record({
      callerId: context.callerId,
      toolName: context.toolName,
      app: app ?? null,
      status,
      durationMs: performance.now() - startMs,
      textLength: context.textLength,
    });
  }
}
