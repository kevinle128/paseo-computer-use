import {
  ComputerUseError,
  ComputerUseToolError,
  toToolErrorCode,
} from "../contract/errors";
import { AbortMonitor } from "./abort";
import { type AuditDetail, AuditLog, type AuditRefusal } from "./audit";
import { assertBrowserAllowed } from "./browsers";
import { assertAppNotBlocked, blockedBundleIds } from "./deny-list";
import { ControlLock } from "./lock";

export * from "./abort";
export * from "./audit";
export * from "./browsers";
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
  // list_apps and list_windows name an app only to filter the list, so a
  // browser is listed even while browsers are refused.
  listing?: boolean;
  displayName?: string;
  textLength?: number;
  // The action fills this in when it learns something the audit entry must
  // keep, such as the frontmost app changing. Read when the entry is written.
  auditDetail?: AuditDetail;
}

export interface PolicyEngineConfig {
  controlLock: ControlLock;
  abortMonitor: AbortMonitor;
  auditLog: AuditLog;
  getExtraBlockedBundleIds?: () => Iterable<string>;
  // Read on every call so turning the setting off stops agents that were
  // created while it was on.
  isEnabled?: () => boolean;
  // Whether web browsers may be read and controlled. Read on every call, like
  // isEnabled.
  allowBrowserApps: () => boolean;
}

export async function withComputerUsePolicy<TInput extends { app?: string }, TResult>(
  engine: PolicyEngineConfig,
  context: PolicyExecutionContext,
  input: TInput,
  action: (resolvedInput: TInput, options: { signal: AbortSignal }) => Promise<TResult>,
): Promise<TResult> {
  const startMs = performance.now();
  const app = (input?.app ?? context.app)?.trim();
  let status: "completed" | "cancelled" | "failed" | "refused" = "completed";
  let refusal: AuditRefusal | undefined;

  if (engine.isEnabled && !engine.isEnabled()) {
    throw new ComputerUseToolError(
      "computer_use_disabled",
      "Computer Use is turned off in Paseo settings. Ask the user to enable it.",
    );
  }

  engine.abortMonitor.assertNotAborted(context.callerId);

  if (app) {
    const extraBlocked = [...(engine.getExtraBlockedBundleIds?.() ?? [])];
    assertAppNotBlocked(app, extraBlocked);
    if (!context.listing) {
      assertBrowserAllowed(app, {
        allowBrowserApps: engine.allowBrowserApps(),
        deniedBundleIds: blockedBundleIds(extraBlocked),
      });
    }
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
      const code = toToolErrorCode(error);
      if (code === "user_active" || code === "stale_state") {
        status = "refused";
        refusal = code;
      } else {
        status = "failed";
      }
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
      ...(context.auditDetail?.userFocusChanged !== undefined
        ? { userFocusChanged: context.auditDetail.userFocusChanged }
        : {}),
      ...(context.auditDetail?.focusWatchDetail !== undefined
        ? { focusWatchDetail: context.auditDetail.focusWatchDetail }
        : {}),
      ...(refusal !== undefined ? { refusal } : {}),
      ...(context.auditDetail?.userActivityDetail !== undefined
        ? { userActivityDetail: context.auditDetail.userActivityDetail }
        : {}),
    });
  }
}
