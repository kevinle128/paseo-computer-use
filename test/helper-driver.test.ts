import { describe, expect, it } from "vitest";
import { ComputerUseError } from "../server/computer-use-mcp/contract/errors";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";
import type {
  HelperCommandName,
  HelperCommands,
} from "../server/computer-use-mcp/contract/helper-protocol";
import { browserTree } from "./menu-fixture";
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
          windowState: {
            text: "App: Editor (pid: 4242, window: 7)\n[0] Legacy\n[1] Other",
            rawTree: tree,
            screenshot: (params as { includeScreenshot?: boolean }).includeScreenshot
              ? { url: "data:image/png;base64,AAAA", width: 400, height: 300, scale: 2 }
              : null,
          },
        },
        "capture.signature": {
          signature: Buffer.alloc(64 * 40, 7).toString("base64"),
          width: 64,
          height: 40,
          windowId: 7,
          windowWidth: 400,
          windowHeight: 300,
        },
        click: { ok: true, verification: { state: "verified", reason: "ax_press_succeeded" } },
        perform_secondary_action: { ok: true, verification: { state: "verified", reason: "ax_action_succeeded" } },
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

// A helper that keeps what the real one keeps: the element each native id
// named in the last read that was allowed to set the cache, and the window of
// that read. An action resolves against that cache and refuses an element whose
// name or frame differs from what the agent saw.
function createCacheModelPort(initial: { names: string[]; windowId: number }) {
  const live = { windowId: initial.windowId };
  const cache = { byPath: new Map<string, string>(), windowId: 0 };
  // Each row keeps its identity (uid) when rows are inserted before it.
  let rows = initial.names.map((name, i) => ({ uid: `row${i}`, name, y: 20 * i }));
  const clicked: string[] = [];
  const windowsUsed: number[] = [];
  const reads: unknown[] = [];
  const treeNow = (): RawAXTree => ({
    window_id: live.windowId,
    root: {
      native_id: "4242:",
      role: "AXApplication",
      children: [
        {
          native_id: "4242:0",
          role: "AXWindow",
          children: rows.map((row, i) => ({
            native_id: `4242:0.${i}`,
            role: "AXButton",
            name: row.name,
            bounds: { x: 0, y: row.y, width: 50, height: 18 },
            states: ["enabled"],
            actions: ["AXPress"],
          })),
        },
      ],
    },
  });
  const port: HelperPort = {
    async request<K extends HelperCommandName>(cmd: K, params: HelperCommands[K]["params"]) {
      if (cmd === "get_app_state") {
        reads.push(params);
        const tree = treeNow();
        if ((params as { cache?: boolean }).cache !== false) {
          cache.byPath = new Map(rows.map((row, i) => [`4242:0.${i}`, row.uid]));
          cache.windowId = live.windowId;
        }
        return {
          app: { bundleIdentifier: "com.example.Editor", displayName: "Editor" },
          windowState: { text: "App: Editor", rawTree: tree, screenshot: null },
        } as HelperCommands[K]["result"];
      }
      if (cmd === "click") {
        const click = params as HelperCommands["click"]["params"];
        if (click.nativeId !== undefined) {
          const uid = cache.byPath.get(click.nativeId);
          const row = rows.find((candidate) => candidate.uid === uid);
          const expected = click.expected;
          if (!row || !expected || row.name !== expected.name || Math.abs(row.y - (expected.frame?.y ?? 0)) > 2) {
            throw new ComputerUseError({ code: "stale_element", message: "changed since the latest snapshot" });
          }
          clicked.push(row.uid);
        } else {
          windowsUsed.push(cache.windowId);
        }
        return { ok: true, verification: { state: "unverified", reason: "events posted; effect not checked" } } as HelperCommands[K]["result"];
      }
      throw new Error(`unexpected command ${cmd}`);
    },
    onEvent: () => () => {},
    stop: async () => {},
  };
  return {
    port,
    clicked,
    windowsUsed,
    reads,
    // A new row appears at the top and every other row moves down.
    insertRowAtTop(name: string) {
      rows = [{ uid: `new${rows.length}`, name, y: 0 }, ...rows.map((row) => ({ ...row, y: row.y + 20 }))];
    },
    moveFocusToWindow(windowId: number) {
      live.windowId = windowId;
    },
  };
}

describe("reads the agent did not ask for", () => {
  const names = ["Delete", "Delete", "Delete", "Delete"];

  it("sets no cache on the read before an action, so a moved row is refused", async () => {
    const model = createCacheModelPort({ names, windowId: 7 });
    const driver = createHelperDriver({ helperPort: model.port });
    await driver.getAppState({ app: "Editor" });
    model.insertRowAtTop("Delete");

    await expect(driver.click({ app: "Editor", elementIndex: 1 })).rejects.toMatchObject({ code: "stale_element" });
    expect(model.clicked).toEqual([]);
    // The agent's read set the cache; the read before the click did not.
    expect(model.reads).toEqual([
      expect.not.objectContaining({ cache: expect.anything() }),
      expect.objectContaining({ cache: false }),
    ]);
  });

  it("sets no cache on the polls of a wait between the read and the click", async () => {
    const model = createCacheModelPort({ names, windowId: 7 });
    const driver = createHelperDriver({ helperPort: model.port });
    await driver.getAppState({ app: "Editor" });
    model.insertRowAtTop("Delete");
    await driver.waitFor({ app: "Editor" }, async (probe) => {
      await probe.readTree({ timeoutMs: 1000 });
      await probe.readTree({ timeoutMs: 1000 });
    });

    await expect(driver.click({ app: "Editor", elementIndex: 1 })).rejects.toMatchObject({ code: "stale_element" });
    expect(model.clicked).toEqual([]);
  });

  it("clicks the element the agent saw when nothing moved", async () => {
    const model = createCacheModelPort({ names, windowId: 7 });
    const driver = createHelperDriver({ helperPort: model.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", elementIndex: 1 });
    expect(model.clicked).toEqual(["row1"]);
  });

  it("keeps the window of the agent's read for a coordinate action", async () => {
    const model = createCacheModelPort({ names, windowId: 7 });
    const driver = createHelperDriver({ helperPort: model.port });
    await driver.getAppState({ app: "Editor" });
    model.moveFocusToWindow(8);
    await driver.click({ app: "Editor", x: 5, y: 5 });
    expect(model.windowsUsed).toEqual([7]);
  });

  it("does not let the screenshot read of a sparse tree replace the cache either", async () => {
    const model = createCacheModelPort({ names: ["Delete", "Delete"], windowId: 7 });
    const driver = createHelperDriver({ helperPort: model.port });
    await driver.getAppState({ app: "Editor", screenshotIfSparse: true });
    expect(model.reads).toEqual([
      expect.not.objectContaining({ cache: expect.anything() }),
      expect.objectContaining({ cache: false, includeScreenshot: true }),
    ]);
  });

  it("limits the read before an action to 1.5 seconds", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 1, y: 1 });
    const reads = fake.calls.filter((call) => call.cmd === "get_app_state");
    expect(reads.at(-1)?.timeoutMs).toBe(1500);
  });

  it("forgets the state kept for an action when the session resets", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 1, y: 1 });
    driver.resetSessionState();
    await driver.getAppState({ app: "Editor" });
    const again = await driver.getAppState({ app: "Editor", reportChange: true });
    expect(again.change).toBeUndefined();
  });
});

describe("menu bar reads", () => {
  it("acts on a menu item found by query without opening its menu", async () => {
    const fake = createFakePort(browserTree());
    const driver = createHelperDriver({ helperPort: fake.port });

    const collapsed = await driver.getAppState({ app: "Editor" });
    expect(collapsed.text).toContain("AXMenuBarItem Edit (menu, 34 items)");
    expect(collapsed.text).not.toContain("Smart Quotes");

    const found = await driver.getAppState({ app: "Editor", query: "Smart Quotes" });
    const index = Number(/\[(\d+)\] AXMenuItem Smart Quotes/.exec(found.text)?.[1]);
    expect(Number.isInteger(index)).toBe(true);
    await driver.performSecondaryAction({ app: "Editor", elementIndex: index, action: "AXShowMenu" });
    await driver.click({ app: "Editor", elementIndex: index });
    expect(fake.clicks()).toEqual([expect.objectContaining({ nativeId: "9:0.2.m.3" })]);
  });

  it("prints every menu when asked", async () => {
    const driver = createHelperDriver({ helperPort: createFakePort(browserTree()).port });
    const all = await driver.getAppState({ app: "Editor", includeMenus: true });
    expect(all.text).toContain("File item 0");
  });
});

describe("sparse tree screenshot", () => {
  const TWO_BUTTONS = treeOf([button("0", "Open", 10), button("1", "Save", 80)]);
  const stateReads = (fake: ReturnType<typeof createFakePort>) =>
    fake.calls.filter((call) => call.cmd === "get_app_state").map((call) => call.params);

  it("takes a screenshot when the tree has 2 indexed elements", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });

    const state = await driver.getAppState({ app: "Editor", includeScreenshot: false, screenshotIfSparse: true });

    expect(state.sparse).toBe(true);
    expect(state.screenshot?.url).toContain("data:image/png");
    expect(state.text).toContain("Screenshot: 800x600 pixels for a 400x300 point window");
    expect(stateReads(fake)).toEqual([
      expect.objectContaining({ includeScreenshot: false }),
      expect.objectContaining({ includeScreenshot: true }),
    ]);
  });

  it("does not take one at exactly 3 indexed elements", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });

    const state = await driver.getAppState({ app: "Editor", includeScreenshot: false, screenshotIfSparse: true });

    expect(state.sparse).toBe(false);
    expect(state.screenshot).toBeNull();
    expect(stateReads(fake)).toHaveLength(1);
  });

  it("reports a sparse tree but takes no screenshot when the caller did not allow one", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });

    const state = await driver.getAppState({ app: "Editor", includeScreenshot: false });

    expect(state.sparse).toBe(true);
    expect(state.screenshot).toBeNull();
    expect(stateReads(fake)).toHaveLength(1);
  });

  it("asks for the screenshot only once when one was already requested", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor", includeScreenshot: true, screenshotIfSparse: true });
    expect(stateReads(fake)).toHaveLength(1);
  });

  it("never calls a query read sparse", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    const state = await driver.getAppState({ app: "Editor", query: "Save", screenshotIfSparse: true });
    expect(state.sparse).toBe(false);
    expect(stateReads(fake)).toHaveLength(1);
  });

  it("still diffs the tree text while it attaches the screenshot again", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor", screenshotIfSparse: true });
    const again = await driver.getAppState({ app: "Editor", screenshotIfSparse: true });
    expect(again.text).toBe("No accessibility changes.");
    expect(again.screenshot).not.toBeNull();
  });
});

describe("image baseline before an action", () => {
  const TWO_BUTTONS = treeOf([button("0", "Open", 10), button("1", "Save", 80)]);
  const captures = (fake: ReturnType<typeof createFakePort>) =>
    fake.calls.filter((call) => call.cmd === "capture.signature");

  it("records the window before an action when the last read was sparse, and hands it out once", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });

    expect(captures(fake)).toHaveLength(1);
    // The image is taken before the click is sent.
    expect(fake.calls.map((call) => call.cmd)).toEqual([
      "get_app_state",
      "capture.signature",
      "get_app_state",
      "click",
    ]);

    const first = await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline());
    expect(first).toMatchObject({ windowId: 7, windowWidth: 400, windowHeight: 300 });
    const second = await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline());
    expect(second).toBeUndefined();
  });

  it("keeps the image through the read after the action but drops it when the agent reads the state", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    await driver.getAppState({ app: "Editor", reportChange: true });
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeDefined();

    await driver.click({ app: "Editor", x: 5, y: 5 });
    await driver.getAppState({ app: "Editor", reportChange: true });
    await driver.getAppState({ app: "Editor" });
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeUndefined();

    await driver.click({ app: "Editor", x: 5, y: 5 });
    await driver.getAppState({ app: "Editor", query: "Save" });
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeUndefined();
  });

  it("takes the image of the window the last full read showed", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    expect(captures(fake)[0]?.params).toMatchObject({ app: "Editor", windowId: 7 });
  });

  it("takes no image before an action on an app whose tree is not sparse", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", elementIndex: 0 });
    expect(captures(fake)).toHaveLength(0);
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeUndefined();
  });

  it("ignores a failed capture and still performs the action", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    const failing: HelperPort = {
      ...fake.port,
      request: async (cmd, params, options) => {
        if (cmd === "capture.signature") {
          throw new Error("no Screen Recording");
        }
        return fake.port.request(cmd, params, options);
      },
    };
    const driver = createHelperDriver({ helperPort: failing });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    expect(fake.clicks()).toHaveLength(1);
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeUndefined();
  });

  it("does not offer an image older than 30 seconds", async () => {
    const fake = createFakePort(TWO_BUTTONS);
    let nowMs = 1_000;
    const driver = createHelperDriver({ helperPort: fake.port, now: () => nowMs });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    nowMs += 30_001;
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeUndefined();

    await driver.click({ app: "Editor", x: 5, y: 5 });
    nowMs += 30_000;
    expect(await driver.waitFor({ app: "Editor" }, async (probe) => probe.takeBaseline())).toBeDefined();
  });
});

describe("helper driver wait probe", () => {
  it("reads trees and signatures under one policy-free call and leaves the diff base alone", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    const first = await driver.getAppState({ app: "Editor" });
    expect(first.text).toContain("[0] AXButton Open");

    const seen = await driver.waitFor({ app: "Editor" }, async (probe) => {
      const tree = await probe.readTree({ timeoutMs: 4000 });
      const signature = await probe.captureSignature({
        windowId: 7,
        region: { x: 1, y: 2, width: 3, height: 4 },
        timeoutMs: 4000,
      });
      return { tree, signature, index: probe.indexElement("4242:1") };
    });

    expect(seen.tree?.root?.children).toHaveLength(3);
    expect(seen.signature.bytes).toHaveLength(64 * 40);
    expect(seen.index).toBe(1);
    const capture = fake.calls.find((call) => call.cmd === "capture.signature");
    expect(capture?.timeoutMs).toBe(4000);
    expect(fake.calls.find((call) => call.cmd === "get_app_state" && call.timeoutMs === 4000)).toBeDefined();
    expect(capture?.params).toEqual({
      app: "Editor",
      blockedBundleIds: expect.arrayContaining(["com.apple.Passwords", "com.google.Chrome"]),
      blockedBundleIdPrefixes: ["com.google.Chrome.app.", "com.apple.Safari.WebApp."],
      windowId: 7,
      region: { x: 1, y: 2, width: 3, height: 4 },
    });
    expect(fake.calls.find((call) => call.cmd === "get_app_state" && (call.params as { includeScreenshot?: boolean }).includeScreenshot === true)).toBeUndefined();

    // The tree did not change, so the next read still diffs against the text the agent saw.
    const next = await driver.getAppState({ app: "Editor" });
    expect(next.text).toBe("No accessibility changes.");
  });

  it("never changes the numbering the agent last read, so an index keeps naming its element", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    const before = driver.elementIds.mappingKey("com.example.Editor");

    // A row is inserted in front: path 1 is now "Open", and path 3 is new.
    fake.setTree(
      treeOf([button("0", "New", 10), button("1", "Open", 80), button("2", "Save", 150), button("3", "Export", 220)]),
    );
    const seen = await driver.waitFor({ app: "Editor" }, async (probe) => {
      await probe.readTree({ timeoutMs: 1000 });
      return { known: probe.indexElement("4242:1"), unknown: probe.indexElement("4242:3") };
    });

    expect(seen).toEqual({ known: 1, unknown: undefined });
    expect(driver.elementIds.mappingKey("com.example.Editor")).toBe(before);
    // Index 1 still carries what the agent read ("Save"), so the helper can refuse the changed element.
    await driver.click({ app: "Editor", elementIndex: 1 });
    expect(fake.clicks()).toEqual([
      expect.objectContaining({ nativeId: "4242:1", expected: expect.objectContaining({ name: "Save" }) }),
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

// An app with several windows. The helper shows one window per read: the one
// named by `windowId`, else the focused one. A closed window fails the read
// the way the real helper does.
function createWindowsPort(initial: { windows: Array<{ id: number; title: string }>; focused: number }) {
  const state = { ...initial, windows: [...initial.windows], active: true };
  const calls: Array<{ cmd: HelperCommandName; params: Record<string, unknown> }> = [];
  const treeFor = (id: number): RawAXTree => {
    const shown = state.windows.find((window) => window.id === id)!;
    const focused = state.windows.find((window) => window.id === state.focused);
    return {
      window_id: id,
      window_title: shown.title,
      other_windows: state.windows.filter((window) => window.id !== id),
      ...(focused ? { focused_window: focused } : {}),
      root: {
        native_id: "4242:",
        role: "AXApplication",
        children: [
          {
            native_id: "4242:0",
            role: "AXWindow",
            name: shown.title,
            window_id: id,
            bounds: { x: 0, y: 0, width: 400, height: 300 },
            children: [
              button("0.0", `Button of ${shown.title}`, 10),
              button("0.1", "Second", 80),
              button("0.2", "Third", 150),
            ],
          },
        ],
      },
    };
  };
  const port: HelperPort = {
    async request<K extends HelperCommandName>(cmd: K, params: HelperCommands[K]["params"]) {
      calls.push({ cmd, params: params as Record<string, unknown> });
      const windowId = (params as { windowId?: number }).windowId;
      if (cmd === "get_app_state") {
        const id = windowId ?? state.focused;
        if (!state.windows.some((window) => window.id === id)) {
          throw new ComputerUseError({ code: "window_gone", message: `Window ${id} is closed.`, windowId: id });
        }
        return {
          app: { bundleIdentifier: "com.example.Editor", displayName: "Editor" },
          isActive: state.active,
          windowState: { text: "App: Editor (pid: 4242)", rawTree: treeFor(id), screenshot: null },
        } as HelperCommands[K]["result"];
      }
      if (windowId !== undefined && !state.windows.some((window) => window.id === windowId)) {
        throw new ComputerUseError({ code: "window_gone", message: `Window ${windowId} is closed.`, windowId });
      }
      return {
        ok: true,
        verification: { state: "unverified", reason: "events posted; effect not checked" },
      } as HelperCommands[K]["result"];
    },
    onEvent: () => () => {},
    stop: async () => {},
  };
  return {
    port,
    calls,
    state,
    close(id: number) {
      state.windows = state.windows.filter((window) => window.id !== id);
    },
    sent: (cmd: HelperCommandName) => calls.filter((call) => call.cmd === cmd).map((call) => call.params),
  };
}

const THREE_WINDOWS = {
  windows: [
    { id: 11, title: "Canvas 1" },
    { id: 12, title: "Mail" },
    { id: 13, title: "VEED" },
  ],
  focused: 11,
};

describe("window targeting", () => {
  it("acts in the window of the last read, with and without an element", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    await driver.click({ app: "Editor", elementIndex: 0 });
    await driver.pressKey({ app: "Editor", key: "Return" });
    await driver.typeText({ app: "Editor", text: "a" });
    await driver.paste({ app: "Editor", text: "a" });
    await driver.drag({ app: "Editor", fromX: 1, fromY: 1, toX: 2, toY: 2 });
    await driver.scroll({ app: "Editor", direction: "down", pages: 1, x: 1, y: 1 });
    await driver.setValue({ app: "Editor", elementIndex: 1, value: "v" });
    await driver.selectText({ app: "Editor", elementIndex: 1, text: "v" });
    await driver.performSecondaryAction({ app: "Editor", elementIndex: 1, action: "AXShowMenu" });
    const actions = fake.calls.filter((call) => call.cmd !== "get_app_state");
    expect(actions).toHaveLength(10);
    for (const action of actions) {
      expect(action.params).toMatchObject({ windowId: 11 });
    }
  });

  it("keeps acting in the window it read after the app focuses another window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    fake.state.focused = 12;
    await driver.click({ app: "Editor", x: 5, y: 5 });
    await driver.pressKey({ app: "Editor", key: "Return" });
    expect(fake.sent("click")).toEqual([expect.objectContaining({ windowId: 11 })]);
    expect(fake.sent("press_key")).toEqual([expect.objectContaining({ windowId: 11 })]);
    // The reads around the action stay on window 11 too.
    const reads = fake.sent("get_app_state").slice(1);
    expect(reads.length).toBeGreaterThan(0);
    for (const read of reads) {
      expect(read).toMatchObject({ windowId: 11 });
    }
  });

  it("refuses to act in a closed window and never falls back to another one", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    fake.close(11);
    await expect(driver.click({ app: "Editor", x: 5, y: 5 })).rejects.toMatchObject({ code: "window_gone" });
    await expect(driver.pressKey({ app: "Editor", key: "Return" })).rejects.toMatchObject({ code: "window_gone" });
    for (const call of fake.calls.filter((entry) => entry.cmd === "click" || entry.cmd === "press_key")) {
      expect(call.params).toMatchObject({ windowId: 11 });
    }
  });

  it("lets an action name a window, and reads that window afterwards", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", windowId: 13, x: 5, y: 5 });
    expect(fake.sent("click")).toEqual([expect.objectContaining({ windowId: 13 })]);
    const state = await driver.getAppState({ app: "Editor", windowId: 13, reportChange: true });
    expect(state.text).toContain("Button of VEED");
  });

  it("searches the window of the last read when a query names no window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    fake.state.focused = 12;
    const found = await driver.getAppState({ app: "Editor", query: "Button" });
    expect(found.text).toContain("Button of Canvas 1");
    expect(fake.sent("get_app_state").at(-1)).toMatchObject({ windowId: 11 });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    expect(fake.sent("click")).toEqual([expect.objectContaining({ windowId: 11 })]);
  });

  it("moves the target when a query names a window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await driver.getAppState({ app: "Editor", windowId: 13, query: "Button" });
    await driver.click({ app: "Editor", x: 5, y: 5 });
    expect(fake.sent("click")).toEqual([expect.objectContaining({ windowId: 13 })]);
  });

  it("refuses an element index from a read of another window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    await expect(driver.click({ app: "Editor", windowId: 12, elementIndex: 0 })).rejects.toMatchObject({
      toolCode: "stale_element",
    });
    expect(fake.sent("click")).toHaveLength(0);
  });

  it("reads another window when asked, and acts there from then on", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    const mail = await driver.getAppState({ app: "Editor", windowId: 12 });
    expect(mail.text).toContain("Button of Mail");
    expect(mail.text).toContain('Other windows: [11] "Canvas 1", [13] "VEED"');
    await driver.click({ app: "Editor", elementIndex: 0 });
    expect(fake.sent("click")).toEqual([expect.objectContaining({ windowId: 12 })]);
  });

  it("reads of a window the agent did not ask for carry the same window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor", windowId: 12 });
    fake.state.focused = 13;
    await driver.waitFor({ app: "Editor" }, async (probe) => probe.readTree({ timeoutMs: 1000 }));
    const wait = fake.sent("get_app_state").at(-1);
    expect(wait).toMatchObject({ windowId: 12, cache: false });
  });

  it("answers a closed window after an action with the change, and reads nothing else", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const original = fake.port.request;
    const port: HelperPort = {
      ...fake.port,
      request: async (cmd, params, options) => {
        const result = await original(cmd, params, options);
        if (cmd === "press_key") {
          fake.close(11);
        }
        return result;
      },
    };
    const closing = createHelperDriver({ helperPort: port });
    await closing.getAppState({ app: "Editor" });
    await closing.pressKey({ app: "Editor", key: "Command+w" });
    const state = await closing.getAppState({ app: "Editor", reportChange: true });
    expect(state.change?.summary).toBe('window closed [11] "Canvas 1"');
    expect(state.text).toContain("Call get_app_state");
    expect(state.text).not.toContain("Mail");
    // The next action still points at the window that is gone.
    await expect(closing.click({ app: "Editor", x: 1, y: 1 })).rejects.toMatchObject({ code: "window_gone" });
  });
});

describe("a closed window named only by the helper", () => {
  it("reports the window the helper says is closed when the app was last read under another name", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    fake.close(11);
    const state = await driver.getAppState({ app: "Example Editor", reportChange: true });
    expect(state.change?.summary).toBe("window closed [11]");
    expect(state.text).toContain("Call get_app_state");
  });

  it("still fails a read that is not after an action", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    fake.close(11);
    await expect(driver.getAppState({ app: "Example Editor" })).rejects.toMatchObject({ code: "window_gone" });
  });
});

describe("the app's focus moving to another window", () => {
  it("adds one line and keeps reading the same window", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const original = fake.port.request;
    const port: HelperPort = {
      ...fake.port,
      request: async (cmd, params, options) => {
        const result = await original(cmd, params, options);
        if (cmd === "press_key") {
          fake.state.focused = 13;
        }
        return result;
      },
    };
    const moving = createHelperDriver({ helperPort: port });
    await moving.getAppState({ app: "Editor" });
    await moving.pressKey({ app: "Editor", key: "Return" });
    const state = await moving.getAppState({ app: "Editor", reportChange: true });
    expect(state.focusedWindow).toBe('focused window is now [13] "VEED"');
    // The read is still of window 11, whose tree did not change.
    expect(state.text).toBe("No accessibility changes.");
    expect(fake.sent("get_app_state").at(-1)).toMatchObject({ windowId: 11 });
  });

  it("says nothing when the focus did not move or the app focuses the window it reads", async () => {
    const fake = createWindowsPort(THREE_WINDOWS);
    const driver = createHelperDriver({ helperPort: fake.port });
    await driver.getAppState({ app: "Editor" });
    expect((await driver.getAppState({ app: "Editor", reportChange: true })).focusedWindow).toBeUndefined();
    fake.state.focused = 12;
    expect((await driver.getAppState({ app: "Editor", reportChange: true })).focusedWindow).toBe(
      'focused window is now [12] "Mail"',
    );
    // Already said once: the same focus is not news.
    expect((await driver.getAppState({ app: "Editor", reportChange: true })).focusedWindow).toBeUndefined();
    fake.state.focused = 11;
    expect((await driver.getAppState({ app: "Editor", reportChange: true })).focusedWindow).toBeUndefined();
  });
});

describe("a text action whose element did not take the focus", () => {
  const refusing = (fake: ReturnType<typeof createFakePort>): HelperPort => ({
    ...fake.port,
    request: async (cmd, params, options) => {
      if (cmd === "type_text" || cmd === "paste_text") {
        return {
          ok: true,
          verification: { state: "unverified", reason: "could not focus element" },
        } as HelperCommands[typeof cmd]["result"];
      }
      return fake.port.request(cmd, params, options);
    },
  });

  it("names the element index the agent used for type_text and paste_text", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const driver = createHelperDriver({ helperPort: refusing(fake) });
    await driver.getAppState({ app: "Editor" });
    const typed = await driver.typeText({ app: "Editor", text: "hi", elementIndex: 1 });
    expect(typed).toMatchObject({ verification: { state: "unverified", reason: "could not focus element [1]" } });
    const pasted = await driver.paste({ app: "Editor", text: "hi", elementIndex: 2 });
    expect(pasted).toMatchObject({ verification: { state: "unverified", reason: "could not focus element [2]" } });
  });
});

describe("the agent an action is for", () => {
  it("is sent with each action so the helper can return a focus note to that agent", async () => {
    const fake = createFakePort(OPEN_SAVE_EXPORT);
    const metas: Array<{ cmd: string; meta: unknown }> = [];
    const port: HelperPort = {
      ...fake.port,
      request: (cmd, params, options) => {
        metas.push({ cmd, meta: options?.meta });
        return fake.port.request(cmd, params, options);
      },
    };
    const driver = createHelperDriver({
      helperPort: port,
      getCallerContext: () => ({ callerId: "agent-a", agentId: null }),
    });
    await driver.getAppState({ app: "Editor" });
    await driver.click({ app: "Editor", elementIndex: 0 });
    expect(metas.filter((entry) => entry.cmd === "click")).toEqual([
      { cmd: "click", meta: { callerId: "agent-a" } },
    ]);
    expect(metas.find((entry) => entry.cmd === "get_app_state")?.meta).toBeUndefined();
  });
});

describe("helper driver after a user_active refusal", () => {
  it("keeps the action blocked when the only read started before the refusal", async () => {
    const base = createFakePort(OPEN_SAVE_EXPORT);
    let refuse = true;
    let clicks = 0;
    let openRead: () => void = () => {};
    const readGate = new Promise<void>((resolve) => {
      openRead = resolve;
    });
    let readStarted: () => void = () => {};
    const started = new Promise<void>((resolve) => {
      readStarted = resolve;
    });
    let gateNextRead = true;
    const port: HelperPort = {
      ...base.port,
      async request(cmd, params, options) {
        if (cmd === "get_app_state" && gateNextRead) {
          gateNextRead = false;
          readStarted();
          await readGate;
        }
        if (cmd === "click") {
          clicks += 1;
          if (refuse) {
            throw new ComputerUseError({
              code: "user_active",
              message: "The user is using TextEdit. Wait a few seconds, call get_app_state again, then retry.",
            });
          }
        }
        return base.port.request(cmd, params, options) as never;
      },
    };
    const driver = createHelperDriver({ helperPort: port });

    const slowRead = driver.getAppState({ app: "Editor" });
    await started;
    await expect(driver.click({ app: "Editor", x: 5, y: 5 })).rejects.toMatchObject({ code: "user_active" });
    refuse = false;
    openRead();
    await slowRead;

    // The read began before the user acted, so it does not show the app as
    // it is now.
    await expect(driver.click({ app: "Editor", x: 5, y: 5 })).rejects.toMatchObject({ toolCode: "stale_state" });
    expect(clicks).toBe(1);

    await driver.getAppState({ app: "Editor" });
    await expect(driver.click({ app: "Editor", x: 5, y: 5 })).resolves.toMatchObject({ ok: true });
    expect(clicks).toBe(2);
  });
});
