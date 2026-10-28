import {
  ComputerUseError,
  ComputerUseTransportError,
  type ToolErrorCode,
  toToolErrorCode,
} from "../contract/errors";
import type { ActionSettlerClock } from "../runtime/action-settler";
import type { NamedCondition, Region } from "./conditions";
import { type ConditionEvaluator, createEvaluator, regionKey } from "./matcher";
import type { SignatureCapture } from "./signature";
import type { WaitProbe } from "./types";

// Tree and image reads are heavy, so the loop reads at this pace.
export const WAIT_POLL_INTERVAL_MS = 300;
// A read gets the time left in the wait, but never less than this, so a read
// near the deadline can still finish.
export const WAIT_MIN_READ_TIMEOUT_MS = 1_000;

export type WaitOutcome =
  | {
      met: string;
      waitedMs: number;
      elementIndex?: number;
      // Set for visual_changed: the image it was compared with.
      baseline?: "before_last_action" | "wait_start";
      // An element matched but the agent's last numbering has no index for it.
      elementUnnumbered?: true;
    }
  | {
      met: null;
      reason: "timeout" | "aborted_by_user" | "app_not_running" | ToolErrorCode;
      waitedMs: number;
      // The error text, or the last read problem when the wait timed out.
      message?: string;
      // Set when a visual_changed condition took its first image before the
      // timeout: the image it compared with.
      baseline?: "before_last_action" | "wait_start";
    };

export interface WaitRequest {
  conditions: NamedCondition[];
  timeoutMs: number;
  windowId?: number;
}

export interface WaitOptions {
  clock: ActionSettlerClock;
  signal?: AbortSignal;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// A busy app can fail an accessibility read for a moment. That is the very
// state a wait exists for, so it does not end the wait.
function isTransientReadFailure(error: unknown): boolean {
  if (error instanceof ComputerUseError) {
    return error.code === "accessibility_error";
  }
  // A read that outlasts its time budget (a hung app) ends that poll only.
  return error instanceof ComputerUseTransportError && /timed out after/.test(error.message);
}

// Polls until one condition is met, the timeout passes, or the user stops it.
// Conditions are checked in the order given, so the first listed one wins when
// several are met on the same poll.
export async function runWait(
  request: WaitRequest,
  probe: WaitProbe,
  options: WaitOptions,
): Promise<WaitOutcome> {
  const { clock, signal } = options;
  const startMs = clock.now();
  const baseline = request.conditions.some(({ condition }) => condition.kind === "visual_changed")
    ? probe.takeBaseline()
    : undefined;
  const evaluators = request.conditions.map(({ condition }) => createEvaluator(condition, { baseline }));
  const needsTree = evaluators.some((evaluator) => evaluator.source === "tree");
  const imageRegions = distinctImageRegions(evaluators);
  const waited = () => Math.round(clock.now() - startMs);
  const readTimeoutMs = () =>
    Math.max(WAIT_MIN_READ_TIMEOUT_MS, Math.ceil(request.timeoutMs - (clock.now() - startMs)));
  let lastReadProblem: string | undefined;

  for (;;) {
    if (signal?.aborted) {
      return { met: null, reason: "aborted_by_user", waitedMs: waited() };
    }

    try {
      const tree = needsTree ? await probe.readTree({ timeoutMs: readTimeoutMs() }) : null;
      const signatures = new Map<string, SignatureCapture>();
      for (const region of imageRegions) {
        signatures.set(
          regionKey(region),
          await probe.captureSignature({
            ...(request.windowId !== undefined ? { windowId: request.windowId } : {}),
            ...(region ? { region } : {}),
            timeoutMs: readTimeoutMs(),
          }),
        );
      }
      const observation = { nowMs: clock.now(), tree, signatures };
      for (const [position, evaluator] of evaluators.entries()) {
        const match = evaluator.evaluate(observation);
        if (match) {
          const elementIndex =
            match.nativeId !== undefined ? probe.indexElement(match.nativeId) : undefined;
          return {
            met: request.conditions[position]!.name,
            waitedMs: waited(),
            ...(elementIndex !== undefined ? { elementIndex } : {}),
            ...(match.baseline ? { baseline: match.baseline } : {}),
            ...(match.nativeId !== undefined && elementIndex === undefined
              ? { elementUnnumbered: true as const }
              : {}),
          };
        }
      }
      lastReadProblem = undefined;
    } catch (error) {
      if (signal?.aborted) {
        return { met: null, reason: "aborted_by_user", waitedMs: waited() };
      }
      if (error instanceof ComputerUseError && error.code === "app_not_found") {
        return { met: null, reason: "app_not_running", waitedMs: waited(), message: error.message };
      }
      if (!isTransientReadFailure(error)) {
        return { met: null, reason: toToolErrorCode(error), waitedMs: waited(), message: errorText(error) };
      }
      lastReadProblem = errorText(error);
    }

    const remainingMs = request.timeoutMs - (clock.now() - startMs);
    if (remainingMs <= 0) {
      return {
        met: null,
        reason: "timeout",
        waitedMs: waited(),
        ...timeoutBaseline(evaluators),
        ...(lastReadProblem ? { message: `The last read failed: ${lastReadProblem}` } : {}),
      };
    }
    await clock.sleep(Math.min(WAIT_POLL_INTERVAL_MS, remainingMs));
  }
}

function distinctImageRegions(evaluators: ConditionEvaluator[]): Array<Region | undefined> {
  const byKey = new Map<string, Region | undefined>();
  for (const evaluator of evaluators) {
    if (evaluator.source === "image") {
      byKey.set(regionKey(evaluator.region), evaluator.region);
    }
  }
  return [...byKey.values()];
}

function timeoutBaseline(evaluators: ConditionEvaluator[]): { baseline?: "before_last_action" | "wait_start" } {
  for (const evaluator of evaluators) {
    const baseline = evaluator.baselineUsed?.();
    if (baseline) return { baseline };
  }
  return {};
}
