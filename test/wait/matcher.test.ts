import { describe, expect, it } from "vitest";
import type { Condition } from "../../server/computer-use-mcp/wait/conditions";
import {
  type Observation,
  createEvaluator,
  regionKey,
} from "../../server/computer-use-mcp/wait/matcher";
import { button, captureOf, node, signatureOf, treeOf } from "./fixtures";
import type { RawAXTree } from "../../server/computer-use-mcp/contract/results";

function observe(tree: RawAXTree | null, nowMs = 0, signatures: Observation["signatures"] = new Map()): Observation {
  return { nowMs, tree, signatures };
}

function evaluate(condition: Condition, tree: RawAXTree | null) {
  return createEvaluator(condition).evaluate(observe(tree));
}

const sheetTree = treeOf(
  node("0.0", "AXSheet", { name: "Save" }),
  button("0.1", "Save"),
);

describe("element conditions", () => {
  it("appears matches when an element fits and not when none does", () => {
    expect(evaluate({ kind: "appears", selector: { role: "AXSheet" } }, sheetTree)).toEqual({ nativeId: "7:0.0" });
    expect(evaluate({ kind: "appears", selector: { role: "AXSheet" } }, treeOf(button("0.0", "Save")))).toBeNull();
  });

  it("disappears matches when no element fits, and never on an unreadable tree", () => {
    const condition: Condition = { kind: "disappears", selector: { role: "AXProgressIndicator" } };
    expect(evaluate(condition, sheetTree)).not.toBeNull();
    expect(evaluate(condition, treeOf(node("0.0", "AXProgressIndicator")))).toBeNull();
    expect(evaluate(condition, null)).toBeNull();
    expect(evaluate(condition, { window_id: 0 })).toBeNull();
  });

  it("matches names ignoring case, exactly or by part, and roles ignoring case too", () => {
    const tree = treeOf(button("0.0", "Save As…"));
    expect(evaluate({ kind: "appears", selector: { name: "save as…" } }, tree)).not.toBeNull();
    expect(evaluate({ kind: "appears", selector: { name: "save" } }, tree)).toBeNull();
    expect(evaluate({ kind: "appears", selector: { nameContains: "SAVE" } }, tree)).not.toBeNull();
    expect(evaluate({ kind: "appears", selector: { role: "axbutton", nameContains: "as" } }, tree)).not.toBeNull();
    expect(evaluate({ kind: "appears", selector: { role: "AXCheckBox", nameContains: "as" } }, tree)).toBeNull();
  });

  it("matches a label held in the description or in a static text value", () => {
    const tree = treeOf(
      node("0.0", "AXImage", { description: "Spinner" }),
      node("0.1", "AXStaticText", { value: "Copying 3 items" }),
    );
    expect(evaluate({ kind: "appears", selector: { name: "spinner" } }, tree)).toEqual({ nativeId: "7:0.0" });
    expect(evaluate({ kind: "appears", selector: { nameContains: "copying" } }, tree)).toEqual({ nativeId: "7:0.1" });
  });

  it("state matches only an element that has the state", () => {
    const tree = treeOf(
      button("0.0", "Open", { states: ["enabled"] }),
      button("0.1", "Send", { states: ["disabled"] }),
      node("0.2", "AXCheckBox", { name: "Remember", states: ["enabled", "checked"] }),
    );
    expect(evaluate({ kind: "state", selector: { name: "send" }, state: "enabled" }, tree)).toBeNull();
    expect(evaluate({ kind: "state", selector: { name: "open" }, state: "enabled" }, tree)).toEqual({ nativeId: "7:0.0" });
    expect(evaluate({ kind: "state", selector: { name: "remember" }, state: "checked" }, tree)).not.toBeNull();
    expect(evaluate({ kind: "state", selector: { name: "open" }, state: "checked" }, tree)).toBeNull();
  });

  it("value matches by equality or by part, case-sensitively", () => {
    const tree = treeOf(node("0.0", "AXTextField", { name: "Status", value: "Done: 3 files" }));
    expect(evaluate({ kind: "value", selector: { name: "status" }, equals: "Done: 3 files" }, tree)).not.toBeNull();
    expect(evaluate({ kind: "value", selector: { name: "status" }, equals: "Done" }, tree)).toBeNull();
    expect(evaluate({ kind: "value", selector: { name: "status" }, contains: "3 files" }, tree)).not.toBeNull();
    expect(evaluate({ kind: "value", selector: { name: "status" }, contains: "done" }, tree)).toBeNull();
  });

  it("value never matches a secure field, whatever the value says", () => {
    const secrets = [
      node("0.0", "AXSecureTextField", { name: "Password", value: "hunter2", states: ["enabled", "secure"] }),
      node("0.1", "AXTextField", { name: "PIN", subrole: "AXSecureTextField", value: "1234" }),
      node("0.2", "AXTextField", { name: "Token", value: "abcd", states: ["secure"] }),
    ];
    for (const secret of secrets) {
      const tree = treeOf(secret);
      expect(evaluate({ kind: "value", selector: { role: secret.role }, contains: secret.value ?? "" }, tree)).toBeNull();
      expect(evaluate({ kind: "value", selector: { name: secret.name ?? "" }, equals: "••••••••" }, tree)).toBeNull();
    }
  });

  it("does not read the value of a secure field through the label either", () => {
    const tree = treeOf(node("0.0", "AXStaticText", { value: "hunter2", states: ["secure"] }));
    expect(evaluate({ kind: "appears", selector: { nameContains: "hunter" } }, tree)).toBeNull();
  });
});

describe("window condition", () => {
  const twoWindows = {
    window_id: 1,
    root: {
      native_id: "7:",
      role: "AXApplication",
      children: [node("0", "AXWindow", { name: "Notes — Edited" }), node("1", "AXWindow", { name: "Find" })],
    },
  } satisfies RawAXTree;

  it("matches a window by part of its title, ignoring case", () => {
    expect(evaluate({ kind: "window", titleContains: "edited", present: true }, twoWindows)).not.toBeNull();
    expect(evaluate({ kind: "window", titleContains: "Draft", present: true }, twoWindows)).toBeNull();
  });

  it("title_not_contains matches a window whose title lacks the text", () => {
    expect(evaluate({ kind: "window", titleNotContains: "Edited", present: true }, twoWindows)).not.toBeNull();
    const onlyEdited = { ...twoWindows, root: { ...twoWindows.root, children: [twoWindows.root.children[0]!] } };
    expect(evaluate({ kind: "window", titleNotContains: "Edited", present: true }, onlyEdited)).toBeNull();
  });

  it("sees the windows the tree lists but does not show", () => {
    const shownAndListed = {
      window_id: 1,
      window_title: "Notes",
      other_windows: [{ id: 2, title: "Find in Notes" }],
      root: {
        native_id: "7:",
        role: "AXApplication",
        children: [node("0", "AXWindow", { name: "Notes - App", window_id: 1 })],
      },
    } satisfies RawAXTree;
    expect(evaluate({ kind: "window", titleContains: "find", present: true }, shownAndListed)).not.toBeNull();
    expect(evaluate({ kind: "window", titleContains: "find", present: false }, shownAndListed)).toBeNull();
    // The window the tree shows is named as the window server names it.
    expect(evaluate({ kind: "window", titleContains: "Notes - App", present: true }, shownAndListed)).toBeNull();
  });

  it("present false matches when no window fits", () => {
    expect(evaluate({ kind: "window", titleContains: "Find", present: false }, twoWindows)).toBeNull();
    expect(evaluate({ kind: "window", titleContains: "Replace", present: false }, twoWindows)).not.toBeNull();
  });
});

describe("conditions that need time", () => {
  it("stable matches once the tree has not changed for quiet_ms", () => {
    const evaluator = createEvaluator({ kind: "stable", quietMs: 500 });
    const a = treeOf(button("0.0", "Open"));
    const b = treeOf(button("0.0", "Open"), button("0.1", "Save"));
    expect(evaluator.evaluate(observe(a, 0))).toBeNull();
    expect(evaluator.evaluate(observe(a, 300))).toBeNull();
    // A change restarts the quiet period.
    expect(evaluator.evaluate(observe(b, 600))).toBeNull();
    expect(evaluator.evaluate(observe(b, 1000))).toBeNull();
    expect(evaluator.evaluate(observe(b, 1100))).not.toBeNull();
  });

  it("visual_stable matches once the image has not changed for quiet_ms", () => {
    const evaluator = createEvaluator({ kind: "visual_stable", quietMs: 600 });
    const seen = (level: number, nowMs: number) =>
      evaluator.evaluate(observe(null, nowMs, new Map([[regionKey(undefined), captureOf(signatureOf(level))]])));
    expect(seen(10, 0)).toBeNull();
    expect(seen(10, 300)).toBeNull();
    expect(seen(200, 600)).toBeNull();
    expect(seen(200, 1100)).toBeNull();
    expect(seen(200, 1200)).not.toBeNull();
  });

  it("visual_stable is not fooled by a slow drift that stays under the limit at each step", () => {
    const evaluator = createEvaluator({ kind: "visual_stable", quietMs: 900 });
    const seen = (level: number, nowMs: number) =>
      evaluator.evaluate(observe(null, nowMs, new Map([[regionKey(undefined), captureOf(signatureOf(level))]])));
    // Each step moves 8 levels (under the cell threshold of 12), but the
    // total drift from the reference passes it.
    expect(seen(100, 0)).toBeNull();
    expect(seen(108, 300)).toBeNull();
    expect(seen(116, 600)).toBeNull();
    expect(seen(124, 900)).toBeNull();
    expect(seen(124, 1200)).toBeNull();
  });

  it("visual_changed compares with the first image of the wait", () => {
    const evaluator = createEvaluator({ kind: "visual_changed" });
    const seen = (level: number) =>
      evaluator.evaluate(observe(null, 0, new Map([[regionKey(undefined), captureOf(signatureOf(level))]])));
    expect(seen(50)).toBeNull();
    expect(seen(50)).toBeNull();
    expect(seen(200)).not.toBeNull();
  });

  it("reads the signature of its own region", () => {
    const region = { x: 0, y: 0, width: 10, height: 10 };
    const evaluator = createEvaluator({ kind: "visual_changed", region });
    expect(evaluator.region).toEqual(region);
    const seen = (level: number) =>
      evaluator.evaluate(observe(null, 0, new Map([[regionKey(region), captureOf(signatureOf(level))]])));
    seen(0);
    expect(seen(255)).not.toBeNull();
  });
});

describe("visual_changed baseline", () => {
  const whole = (level: number, windowId = 5) =>
    new Map([[regionKey(undefined), captureOf(signatureOf(level), windowId)]]);
  const baseline = (level: number, windowId = 5) => captureOf(signatureOf(level), windowId);

  it("matches on the first capture when the window already differs from the image before the action", () => {
    const evaluator = createEvaluator({ kind: "visual_changed" }, { baseline: baseline(20) });
    expect(evaluator.region).toBeUndefined();
    expect(evaluator.evaluate(observe(null, 0, whole(220)))).toEqual({ baseline: "before_last_action" });
  });

  it("waits for a change when the window still equals the image before the action", () => {
    const evaluator = createEvaluator({ kind: "visual_changed" }, { baseline: baseline(20) });
    expect(evaluator.evaluate(observe(null, 0, whole(20)))).toBeNull();
    expect(evaluator.evaluate(observe(null, 300, whole(220)))).toEqual({ baseline: "before_last_action" });
  });

  it("falls back to the first capture of the wait when the baseline shows another window", () => {
    const evaluator = createEvaluator({ kind: "visual_changed" }, { baseline: baseline(20, 9) });
    expect(evaluator.evaluate(observe(null, 0, whole(220)))).toBeNull();
    expect(evaluator.evaluate(observe(null, 300, whole(220)))).toBeNull();
    expect(evaluator.evaluate(observe(null, 600, whole(20)))).toEqual({ baseline: "wait_start" });
  });

  it("reports the first capture of the wait when there is no baseline", () => {
    const evaluator = createEvaluator({ kind: "visual_changed" });
    expect(evaluator.evaluate(observe(null, 0, whole(20)))).toBeNull();
    expect(evaluator.evaluate(observe(null, 300, whole(220)))).toEqual({ baseline: "wait_start" });
  });

  it("compares only the cells under the region against the baseline", () => {
    const region = { x: 0, y: 0, width: 25, height: 20 };
    const evaluator = createEvaluator({ kind: "visual_changed", region }, { baseline: baseline(20) });
    // The change is far from the region: cells outside it do not count.
    const elsewhere = signatureOf(20);
    elsewhere.fill(240, 30 * 64, 40 * 64);
    expect(
      evaluator.evaluate(observe(null, 0, new Map([[regionKey(undefined), captureOf(elsewhere)]]))),
    ).toBeNull();
    const inside = signatureOf(20);
    inside[0] = 240;
    inside[1] = 240;
    inside[64] = 240;
    inside[65] = 240;
    expect(
      evaluator.evaluate(observe(null, 300, new Map([[regionKey(undefined), captureOf(inside)]]))),
    ).toEqual({ baseline: "before_last_action" });
  });
});
