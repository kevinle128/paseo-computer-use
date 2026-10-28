import { describe, expect, it } from "vitest";
import { ComputerUseError, ComputerUseToolError, ComputerUseTransportError } from "../../server/computer-use-mcp/contract/errors";
import type { RawAXTree } from "../../server/computer-use-mcp/contract/results";
import type { ActionSettlerClock } from "../../server/computer-use-mcp/runtime/action-settler";
import type { NamedCondition } from "../../server/computer-use-mcp/wait/conditions";
import { runWait, WAIT_MIN_READ_TIMEOUT_MS, WAIT_POLL_INTERVAL_MS } from "../../server/computer-use-mcp/wait/poll-loop";
import type { WaitProbe } from "../../server/computer-use-mcp/wait/types";
import { button, captureOf, signatureOf, treeOf } from "./fixtures";

// A clock that only moves when the loop sleeps, so a wait of 30 s runs at once.
function fakeClock() {
  let nowMs = 1_000;
  const sleeps: number[] = [];
  const clock: ActionSettlerClock = {
    now: () => nowMs,
    sleep: async (ms) => {
      sleeps.push(ms);
      nowMs += ms;
    },
  };
  return { clock, sleeps, advance: (ms: number) => (nowMs += ms) };
}

function fakeProbe(overrides: Partial<WaitProbe> = {}) {
  const calls = { readTree: 0, captureSignature: [] as unknown[] };
  const probe: WaitProbe = {
    readTree: async () => {
      calls.readTree += 1;
      return treeOf();
    },
    captureSignature: async (params) => {
      calls.captureSignature.push(params);
      return captureOf(signatureOf(100));
    },
    takeBaseline: () => undefined,
    indexElement: () => undefined,
    ...overrides,
  };
  return { probe, calls };
}

const appearsSheet: NamedCondition = {
  name: "sheet",
  condition: { kind: "appears", selector: { role: "AXSheet" } },
};
const sheetTree = treeOf({ native_id: "7:0.0", role: "AXSheet", name: "Save" });

describe("wait poll loop", () => {
  it("is met on the third poll, 300 ms apart", async () => {
    const { clock, sleeps } = fakeClock();
    let reads = 0;
    const { probe } = fakeProbe({
      readTree: async () => (++reads < 3 ? treeOf() : sheetTree),
      indexElement: (nativeId) => (nativeId === "7:0.0" ? 5 : undefined),
    });

    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 5000 }, probe, { clock });

    expect(outcome).toEqual({ met: "sheet", waitedMs: 2 * WAIT_POLL_INTERVAL_MS, elementIndex: 5 });
    expect(sleeps).toEqual([WAIT_POLL_INTERVAL_MS, WAIT_POLL_INTERVAL_MS]);
  });

  it("flags a matched element the agent has no index for", async () => {
    const { clock } = fakeClock();
    const { probe } = fakeProbe({ readTree: async () => sheetTree });
    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 5000 }, probe, { clock });
    expect(outcome).toEqual({ met: "sheet", waitedMs: 0, elementUnnumbered: true });
  });

  it("times out after the timeout, with a last poll at the deadline", async () => {
    const { clock, sleeps } = fakeClock();
    const { probe, calls } = fakeProbe();

    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 1000 }, probe, { clock });

    expect(outcome).toEqual({ met: null, reason: "timeout", waitedMs: 1000 });
    // The sleeps add up to the timeout and the last one is shortened to fit.
    expect(sleeps).toEqual([300, 300, 300, 100]);
    expect(calls.readTree).toBe(5);
  });

  it("returns the first listed condition when several are met on one poll", async () => {
    const { clock } = fakeClock();
    const { probe } = fakeProbe({ readTree: async () => treeOf(button("0.0", "Open"), { native_id: "7:0.1", role: "AXSheet" }) });
    const outcome = await runWait(
      {
        conditions: [
          { name: "second", condition: { kind: "appears", selector: { role: "AXSheet" } } },
          { name: "first-in-tree", condition: { kind: "appears", selector: { name: "Open" } } },
        ],
        timeoutMs: 1000,
      },
      probe,
      { clock },
    );
    expect(outcome).toMatchObject({ met: "second" });
  });

  it("ends at the next poll when the user stops it", async () => {
    const { clock } = fakeClock();
    const controller = new AbortController();
    let reads = 0;
    const { probe } = fakeProbe({
      readTree: async () => {
        reads += 1;
        if (reads === 2) controller.abort();
        return treeOf();
      },
    });

    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 30_000 }, probe, {
      clock,
      signal: controller.signal,
    });

    expect(outcome).toMatchObject({ met: null, reason: "aborted_by_user" });
    expect(reads).toBe(2);
  });

  it("reports an abort the helper raised during a read", async () => {
    const { clock } = fakeClock();
    const { probe } = fakeProbe({
      readTree: async () => {
        throw new ComputerUseError({ code: "aborted_by_user", message: "stopped" });
      },
    });
    expect(await runWait({ conditions: [appearsSheet], timeoutMs: 5000 }, probe, { clock })).toMatchObject({
      met: null,
      reason: "aborted_by_user",
    });
  });

  it("reports app_not_running when the app quits mid-wait", async () => {
    const { clock } = fakeClock();
    let reads = 0;
    const { probe } = fakeProbe({
      readTree: async () => {
        if (++reads === 3) {
          throw new ComputerUseError({ code: "app_not_found", message: "No running app matches 'Notes'." });
        }
        return treeOf();
      },
    });
    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 30_000 }, probe, { clock });
    expect(outcome).toMatchObject({ met: null, reason: "app_not_running", waitedMs: 600 });
  });

  it("returns a tool error code for a refusal, without polling again", async () => {
    const { clock } = fakeClock();
    const { probe, calls } = fakeProbe({
      readTree: async () => {
        throw new ComputerUseToolError("app_blocked", "blocked");
      },
    });
    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 5000 }, probe, { clock });
    expect(outcome).toMatchObject({ met: null, reason: "app_blocked", message: "blocked" });
    expect(calls.readTree).toBe(0);
  });

  it("keeps waiting through a busy app's failed read and says so on timeout", async () => {
    const { clock } = fakeClock();
    let reads = 0;
    const { probe } = fakeProbe({
      readTree: async (): Promise<RawAXTree> => {
        if (++reads === 1) {
          throw new ComputerUseError({ code: "accessibility_error", message: "not responding" });
        }
        return sheetTree;
      },
    });
    expect(await runWait({ conditions: [appearsSheet], timeoutMs: 5000 }, probe, { clock })).toMatchObject({
      met: "sheet",
    });

    const failing = fakeProbe({
      readTree: async () => {
        throw new ComputerUseError({ code: "accessibility_error", message: "not responding" });
      },
    });
    const timedOut = await runWait({ conditions: [appearsSheet], timeoutMs: 600 }, failing.probe, { clock });
    expect(timedOut).toMatchObject({ met: null, reason: "timeout", message: expect.stringContaining("not responding") });
  });

  it("gives each read the time left in the wait, with a floor", async () => {
    const { clock } = fakeClock();
    const budgets: number[] = [];
    const { probe } = fakeProbe({
      readTree: async ({ timeoutMs }) => {
        budgets.push(timeoutMs);
        return treeOf();
      },
    });
    await runWait({ conditions: [appearsSheet], timeoutMs: 2000 }, probe, { clock });
    expect(budgets.slice(0, 4)).toEqual([2000, 1700, 1400, 1100]);
    // Near the deadline the budget stops at the floor instead of shrinking to nothing.
    expect(budgets.slice(4).every((ms) => ms === WAIT_MIN_READ_TIMEOUT_MS)).toBe(true);
  });

  it("treats a read that times out as one failed poll, and still ends at the deadline", async () => {
    const { clock } = fakeClock();
    const { probe } = fakeProbe({
      readTree: async () => {
        throw new ComputerUseTransportError("Helper command 'get_app_state' (id=3) timed out after 1000ms.");
      },
    });
    const outcome = await runWait({ conditions: [appearsSheet], timeoutMs: 900 }, probe, { clock });
    expect(outcome).toMatchObject({ met: null, reason: "timeout", message: expect.stringContaining("timed out") });
  });

  it("ends at once for a missing permission or an invalid region", async () => {
    for (const [code, reason] of [
      ["permission_missing", "permission_missing"],
      ["malformed_request", "invalid_arguments"],
    ] as const) {
      const { clock, sleeps } = fakeClock();
      const { probe } = fakeProbe({
        captureSignature: async () => {
          throw new ComputerUseError({ code, message: "refused" });
        },
      });
      const outcome = await runWait(
        { conditions: [{ name: "c", condition: { kind: "visual_changed" } }], timeoutMs: 30_000 },
        probe,
        { clock },
      );
      expect(outcome).toMatchObject({ met: null, reason, message: "refused" });
      expect(sleeps).toEqual([]);
    }
  });

  it("reads the tree only for tree conditions, and one image per distinct region", async () => {
    const { clock } = fakeClock();
    const region = { x: 1, y: 2, width: 30, height: 40 };
    const { probe, calls } = fakeProbe();
    const outcome = await runWait(
      {
        conditions: [
          { name: "settled", condition: { kind: "visual_stable", quietMs: 300 } },
          { name: "changed", condition: { kind: "visual_changed" } },
          { name: "corner", condition: { kind: "visual_changed", region } },
        ],
        timeoutMs: 5000,
        windowId: 9,
      },
      probe,
      { clock },
    );
    expect(outcome).toMatchObject({ met: "settled" });
    expect(calls.readTree).toBe(0);
    // Two polls (the second one meets the 300 ms quiet period), two regions each.
    expect(calls.captureSignature).toEqual([
      { windowId: 9, timeoutMs: 5000 },
      { windowId: 9, region, timeoutMs: 5000 },
      { windowId: 9, timeoutMs: 4700 },
      { windowId: 9, region, timeoutMs: 4700 },
    ]);
  });

  it("reports the baseline on a timeout of visual_changed", async () => {
    for (const [baseline, expected] of [
      [captureOf(signatureOf(100)), "before_last_action"],
      [undefined, "wait_start"],
    ] as const) {
      const { clock } = fakeClock();
      // The window never changes from the image the probe returns on every poll.
      const { probe } = fakeProbe({ takeBaseline: () => baseline });
      const outcome = await runWait(
        { conditions: [{ name: "redrawn", condition: { kind: "visual_changed" } }], timeoutMs: 900 },
        probe,
        { clock },
      );
      expect(outcome).toMatchObject({ met: null, reason: "timeout", baseline: expected });
    }
  });

  it("leaves the baseline out of a timeout that had no image", async () => {
    const { clock } = fakeClock();
    const { probe } = fakeProbe({
      captureSignature: async () => {
        throw new ComputerUseTransportError("capture timed out after 1000 ms");
      },
    });
    const outcome = await runWait(
      { conditions: [{ name: "redrawn", condition: { kind: "visual_changed" } }], timeoutMs: 900 },
      probe,
      { clock },
    );
    expect(outcome).toMatchObject({ met: null, reason: "timeout" });
    expect(outcome).not.toHaveProperty("baseline");
  });

  it("compares with the image before the last action and reports which baseline it used", async () => {
    const { clock } = fakeClock();
    let taken = 0;
    const { probe } = fakeProbe({
      takeBaseline: () => {
        taken += 1;
        return captureOf(signatureOf(20));
      },
      captureSignature: async () => captureOf(signatureOf(220)),
    });
    const outcome = await runWait(
      { conditions: [{ name: "redrawn", condition: { kind: "visual_changed" } }], timeoutMs: 5000 },
      probe,
      { clock },
    );
    expect(outcome).toEqual({ met: "redrawn", waitedMs: 0, baseline: "before_last_action" });
    expect(taken).toBe(1);
  });

  it("does not take the baseline for a wait that has no visual_changed condition", async () => {
    const { clock } = fakeClock();
    let taken = 0;
    const { probe } = fakeProbe({
      takeBaseline: () => {
        taken += 1;
        return undefined;
      },
    });
    await runWait({ conditions: [appearsSheet], timeoutMs: 300 }, probe, { clock });
    expect(taken).toBe(0);
  });

  it("waits on tree and image conditions together", async () => {
    const { clock } = fakeClock();
    let level = 100;
    const { probe } = fakeProbe({ captureSignature: async () => captureOf(signatureOf(level)) });
    let reads = 0;
    const outcome = await runWait(
      {
        conditions: [
          appearsSheet,
          { name: "changed", condition: { kind: "visual_changed" } },
        ],
        timeoutMs: 5000,
      },
      { ...probe, readTree: async () => { if (++reads === 2) level = 220; return treeOf(); } },
      { clock },
    );
    expect(outcome).toMatchObject({ met: "changed" });
    expect(reads).toBe(2);
  });
});
