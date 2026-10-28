import { condenseAccessibilityTree } from "../ax/accessibility-tree";
import { ElementIds } from "../ax/element-ids";
import { appWindows } from "../ax/windows";
import type { RawAXNode, RawAXTree } from "../contract/results";
import type { Condition, ElementSelector, Region } from "./conditions";
import { cropSignature, type PreActionBaseline, type SignatureCapture, signaturesDiffer } from "./signature";

// What one poll saw. Signatures are keyed by `regionKey`.
export interface Observation {
  nowMs: number;
  tree: RawAXTree | null;
  signatures: ReadonlyMap<string, SignatureCapture>;
}

export interface ConditionMatch {
  // The element that satisfied the condition, when it is about one.
  nativeId?: string;
  // Which image a visual_changed compared against.
  baseline?: "before_last_action" | "wait_start";
}

// One evaluator per condition per wait. It may keep state between polls
// (when the tree last changed), so it is never shared between waits.
export interface ConditionEvaluator {
  readonly source: "tree" | "image";
  // The region of the window image it compares; undefined means the whole window.
  readonly region?: Region;
  evaluate(observation: Observation): ConditionMatch | null;
  // Which image a visual_changed compared against so far; undefined before
  // its first image. Lets a timeout report it too.
  baselineUsed?(): "before_last_action" | "wait_start" | undefined;
}

export function regionKey(region: Region | undefined): string {
  return region ? `${region.x},${region.y},${region.width},${region.height}` : "window";
}

function* allNodes(node: RawAXNode): Generator<RawAXNode> {
  if (node.states?.some((s) => s.toLowerCase() === "hidden")) {
    return;
  }
  yield node;
  for (const child of node.children ?? []) {
    yield* allNodes(child);
  }
}

function isSecure(node: RawAXNode): boolean {
  return (
    node.role === "AXSecureTextField" ||
    node.subrole === "AXSecureTextField" ||
    (node.states ?? []).some((s) => s.toLowerCase() === "secure")
  );
}

// The texts a person would call the element's name. A static text shows its
// text as a value, so that counts too; a secure field never offers its value.
function labelsOf(node: RawAXNode): string[] {
  const labels = [node.name, node.description];
  if (node.role === "AXStaticText" && !isSecure(node)) {
    labels.push(node.value);
  }
  return labels.filter((label): label is string => typeof label === "string" && label.trim() !== "");
}

function matchesSelector(node: RawAXNode, selector: ElementSelector): boolean {
  if (selector.role !== undefined && node.role.toLowerCase() !== selector.role.toLowerCase()) {
    return false;
  }
  const nameLower = selector.name?.toLowerCase();
  const containsLower = selector.nameContains?.toLowerCase();
  if (nameLower === undefined && containsLower === undefined) {
    return true;
  }
  const labels = labelsOf(node).map((label) => label.trim().toLowerCase());
  if (nameLower !== undefined && !labels.includes(nameLower.trim())) {
    return false;
  }
  if (containsLower !== undefined && !labels.some((label) => label.includes(containsLower))) {
    return false;
  }
  return true;
}

function findElement(
  tree: RawAXTree | null,
  predicate: (node: RawAXNode) => boolean,
): RawAXNode | undefined {
  if (!tree?.root) {
    return undefined;
  }
  for (const node of allNodes(tree.root)) {
    if (predicate(node)) {
      return node;
    }
  }
  return undefined;
}

function matchOf(node: RawAXNode | undefined): ConditionMatch | null {
  return node ? { nativeId: node.native_id } : null;
}

// The windows of the app: the one the tree shows, and the others it lists.
// Sheets and popovers are not windows.
function windowTitles(tree: RawAXTree | null): string[] | null {
  if (!tree?.root) {
    return null;
  }
  return appWindows(tree).map((window) => window.title);
}

// Tracks how long a value has stayed the same, using the time of each poll.
class QuietTracker<T> {
  private current: { value: T; since: number } | undefined;

  constructor(private readonly changed: (a: T, b: T) => boolean) {}

  // Returns how long `value` has been unchanged as of `nowMs`.
  quietFor(value: T, nowMs: number): number {
    if (this.current === undefined || this.changed(this.current.value, value)) {
      this.current = { value, since: nowMs };
    }
    return nowMs - this.current.since;
  }
}

export function createEvaluator(
  condition: Condition,
  context: { baseline?: PreActionBaseline } = {},
): ConditionEvaluator {
  switch (condition.kind) {
    case "appears":
      return treeEvaluator((obs) => matchOf(findElement(obs.tree, (n) => matchesSelector(n, condition.selector))));
    case "disappears":
      return treeEvaluator((obs) => {
        // An unreadable tree proves nothing, so it never counts as gone.
        if (!obs.tree?.root) return null;
        return findElement(obs.tree, (n) => matchesSelector(n, condition.selector)) ? null : {};
      });
    case "state": {
      const wanted = condition.state;
      return treeEvaluator((obs) =>
        matchOf(
          findElement(
            obs.tree,
            (n) =>
              matchesSelector(n, condition.selector) &&
              (n.states ?? []).some((s) => s.toLowerCase() === wanted),
          ),
        ),
      );
    }
    case "value":
      return treeEvaluator((obs) =>
        matchOf(
          findElement(obs.tree, (n) => {
            // The secure check comes first: the value of a secure field is
            // never read, not even to compare it.
            if (isSecure(n) || !matchesSelector(n, condition.selector)) return false;
            const nodeValue = n.value;
            if (nodeValue === undefined) return false;
            return condition.equals !== undefined
              ? nodeValue === condition.equals
              : nodeValue.includes(condition.contains ?? "");
          }),
        ),
      );
    case "window":
      return treeEvaluator((obs) => {
        const titles = windowTitles(obs.tree);
        if (titles === null) return null;
        const matching = titles.filter((title) => {
          const lower = title.toLowerCase();
          if (condition.titleContains !== undefined) {
            return lower.includes(condition.titleContains.toLowerCase());
          }
          if (condition.titleNotContains !== undefined) {
            return !lower.includes(condition.titleNotContains.toLowerCase());
          }
          return true;
        });
        return (matching.length > 0) === condition.present ? {} : null;
      });
    case "stable": {
      const tracker = new QuietTracker<string>((a, b) => a !== b);
      return treeEvaluator((obs) => {
        if (!obs.tree?.root) return null;
        const condensed = condenseAccessibilityTree(obs.tree, {
          elementIds: new ElementIds(),
          app: "wait",
        });
        return tracker.quietFor(condensed, obs.nowMs) >= condition.quietMs ? {} : null;
      });
    }
    case "visual_stable": {
      const tracker = new QuietTracker<Uint8Array>(signaturesDiffer);
      return imageEvaluator(condition.region, (capture, nowMs) =>
        tracker.quietFor(capture.bytes, nowMs) >= condition.quietMs ? {} : null,
      );
    }
    case "visual_changed": {
      const { baseline } = context;
      const { region } = condition;
      // With a baseline the whole window is captured, because the baseline
      // is a whole-window signature; a region then compares the same cells of
      // both. Without one, the region is captured by itself.
      const view = (capture: SignatureCapture) =>
        baseline && region ? cropSignature(capture, region) : capture.bytes;
      let reference: { view: Uint8Array; used: "before_last_action" | "wait_start" } | undefined;
      const evaluator = imageEvaluator(baseline ? undefined : region, (capture) => {
        if (reference === undefined) {
          // A baseline of another window says nothing about this one.
          const usable = baseline !== undefined && baseline.windowId === capture.windowId;
          reference = {
            view: view(usable ? baseline : capture),
            used: usable ? "before_last_action" : "wait_start",
          };
          if (!usable) return null;
        }
        return signaturesDiffer(reference.view, view(capture)) ? { baseline: reference.used } : null;
      });
      return { ...evaluator, baselineUsed: () => reference?.used };
    }
    default: {
      const unhandled: never = condition;
      throw new Error(`Unhandled wait condition: ${JSON.stringify(unhandled)}`);
    }
  }
}

function treeEvaluator(evaluate: (observation: Observation) => ConditionMatch | null): ConditionEvaluator {
  return { source: "tree", evaluate };
}

function imageEvaluator(
  region: Region | undefined,
  evaluate: (capture: SignatureCapture, nowMs: number) => ConditionMatch | null,
): ConditionEvaluator {
  const key = regionKey(region);
  return {
    source: "image",
    ...(region ? { region } : {}),
    evaluate: (observation) => {
      const capture = observation.signatures.get(key);
      return capture ? evaluate(capture, observation.nowMs) : null;
    },
  };
}
