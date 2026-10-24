import { describe, expect, it } from "vitest";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";
import type {
  HelperCommandName,
  HelperCommands,
} from "../server/computer-use-mcp/contract/helper-protocol";
import type { RawAXNode, RawAXTree } from "../server/computer-use-mcp/contract/results";
import { createHelperDriver, typeTextTimeoutMs, screenshotCoordinateNote } from "../server/computer-use-mcp/facade/helper-driver";

function button(path: string, name: string, x: number): RawAXNode {
  return {
    native_id: `4242:${path}`,
    role: "AXButton",
    name,
    bounds: { x, y: 10, width: 60, height: 20 },
    states: ["enabled"],
    actions: ["AXPress"],
  };
}

function treeOf(buttons: RawAXNode[]): RawAXTree {
  return {
    window_id: 7,
    root: { native_id: "4242:", role: "AXApplication", name: "Editor", children: buttons },
  };
}

const OPEN_SAVE_EXPORT = treeOf([
  button("0", "Open", 10),
  button("1", "Save", 80),
  button("2", "Export", 150),
]);

// A fake helper port that serves whatever tree the test sets and records
// every request, so tests can check what the plugin sent to the helper.
function createFakePort(initialTree: RawAXTree) {
  let tree = initialTree;
  const calls: Array<{ cmd: HelperCommandName; params: unknown; timeoutMs?: number }> = [];
  const port: HelperPort = {
    async request<K extends HelperCommandName>(
      cmd: K,
      params: HelperCommands[K]["params"],
      options?: { timeoutMs?: number },
    ): Promise<HelperCommands[K]["result"]> {
      calls.push({ cmd, params, timeoutMs: options?.timeoutMs });
      const replies: { [C in HelperCommandName]?: HelperCommands[C]["result"] } = {
        get_app_state: {
          app: { bundleIdentifier: "com.example.Editor", displayName: "Editor" },
          // Legacy numbered lines after the header must never reach the model.
          windowState: { text: "App: Editor (pid: 4242, window: 7)\n[0] Legacy\n[1] Other", rawTree: tree },
        },
        click: { ok: true, verification: { state: "verified", reason: "ax_press_succeeded" } },
        type_text: { ok: true, verification: { state: "verified", reason: "field_value_matches" } },
      };
      const reply = replies[cmd];
      if (reply === undefined) {
        throw new Error(`unexpected command ${cmd}`);
      }
      return reply;
    },
    onEvent: () => () => {},
    stop: async () => {},
  };
  return {
    port,
    calls,
    setTree(next: RawAXTree) {
      tree = next;
    },
    clicks: () => calls.filter((call) => call.cmd === "click").map((call) => call.params),
  };
}

describe("helper driver element indices", () => {
  it("returns the full tree after a query read changed the numbering", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });

    const first = await driver.getAppState({ app: "Editor" });
    expect(first.text).toContain("[0] AXButton Open");

    const filtered = await driver.getAppState({ app: "Editor", query: "export" });
    expect(filtered.text).toContain("[0] AXButton Export");
    expect(filtered.text).not.toContain("Open");

    // Index 0 now means Open again, so the model must see the full numbering
    // instead of a "no changes" diff against the first full read.
    const again = await driver.getAppState({ app: "Editor" });
    expect(again.text).not.toBe("No accessibility changes.");
    expect(again.text).toContain("[0] AXButton Open");
    expect(again.text).toContain("[2] AXButton Export");

    await driver.click({ app: "Editor", elementIndex: 0 });
    expect(fake.clicks()).toEqual([expect.objectContaining({ nativeId: "4242:0" })]);
  });

  it("diffs a full read only when the numbering is the same as the last read", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    const same = await driver.getAppState({ app: "Editor" });
    expect(same.text).toBe("No accessibility changes.");

    fake.setTree(treeOf([button("0", "Open", 10), button("1", "Save As", 80), button("2", "Export", 150)]));
    const renamed = await driver.getAppState({ app: "Editor" });
    expect(renamed.text).toContain("Accessibility diff:");
    expect(renamed.text).toContain("+ ");
    expect(renamed.text).toContain("[1] AXButton Save As");
  });

  it("keeps only the helper header line and numbers elements from the raw tree", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    const state = await driver.getAppState({ app: "Editor" });
    const lines = state.text.split("\n");
    expect(lines[0]).toBe("App: Editor (pid: 4242, window: 7)");
    expect(state.text).not.toContain("Legacy");
    expect(state.text).not.toContain("Other");

    await driver.click({ app: "Editor", elementIndex: 1 });
    expect(fake.clicks()).toEqual([expect.objectContaining({ nativeId: "4242:1" })]);
  });

  it("does not send the diff or query options to the helper", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor", query: "save" });
    const [params] = fake.calls.filter((call) => call.cmd === "get_app_state").map((call) => call.params);
    expect(params).not.toHaveProperty("disableDiff");
    expect(params).not.toHaveProperty("query");
  });

  it("sends the element as this agent saw it, even after another agent read a changed tree", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    // The service creates one driver per caller, all sharing one helper.
    const agentA = createHelperDriver({ helperPort: fake.port });
    const agentB = createHelperDriver({ helperPort: fake.port });

    await agentA.getAppState({ app: "Editor" });
    // A row is inserted in front, so the element at path 0 is now different.
    fake.setTree(treeOf([button("0", "New", 10), button("1", "Open", 80), button("2", "Save", 150)]));
    await agentB.getAppState({ app: "Editor" });

    await agentA.click({ app: "Editor", elementIndex: 0 });
    expect(fake.clicks()).toEqual([
      expect.objectContaining({
        nativeId: "4242:0",
        expected: { role: "AXButton", name: "Open", frame: { x: 10, y: 10, width: 60, height: 20 } },
      }),
    ]);
  });
});

describe("screenshot coordinate note", () => {
  it("divides Retina screenshot pixels by the reported scale", () => {
    expect(screenshotCoordinateNote({ url: "data:", width: 1280, height: 800, scale: 2 })).toBe(
      "Screenshot: 2560x1600 pixels for a 1280x800 point window. The tree and action tools use window points: divide a screenshot pixel position by 2.",
    );
  });

  it("says pixels equal points at scale 1 or when the scale is missing", () => {
    for (const scale of [1, undefined, Number.NaN]) {
      expect(screenshotCoordinateNote({ url: "data:", width: 640, height: 480, scale })).toBe(
        "Screenshot: 640x480 pixels for a 640x480 point window. Screenshot pixels equal window points, the coordinates the tree and action tools use.",
      );
    }
  });
});

describe("helper driver type_text timeout", () => {
  it("gives long text enough time to finish typing", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    // 5000 units take about 50 s at the helper's typing pace; a flat 30 s
    // timeout stopped this call part way through in a real run.
    await driver.typeText({ app: "Editor", text: "a".repeat(5000) });
    const [call] = fake.calls.filter((c) => c.cmd === "type_text");
    expect(call?.timeoutMs).toBe(180_000);
    expect(typeTextTimeoutMs("")).toBe(30_000);
  });
});
