import { describe, expect, it } from "vitest";
import {
  condenseAccessibilityTree,
  countIndexedElements,
  formatAccessibilityDiff,
  normalizeRole,
  SPARSE_TREE_ELEMENT_LIMIT,
} from "../server/computer-use-mcp/ax/accessibility-tree";
import { ElementIds } from "../server/computer-use-mcp/ax/element-ids";
import { focusedWindowUnlisted } from "../server/computer-use-mcp/ax/windows";
import type { RawAXTree } from "../server/computer-use-mcp/contract/results";
import { browserTree } from "./menu-fixture";

describe("AX Condenser & ElementIds", () => {
  it("normalizes roles for containers, text, and menu items", () => {
    expect(normalizeRole("group")).toBe("container");
    expect(normalizeRole("panel")).toBe("container");
    expect(normalizeRole("filler")).toBe("container");
    expect(normalizeRole("section")).toBe("container");
    expect(normalizeRole("generic")).toBe("container");
    expect(normalizeRole("text")).toBe("text");
    expect(normalizeRole("static")).toBe("text");
    expect(normalizeRole("label")).toBe("text");
    expect(normalizeRole("menu item")).toBe("");
    expect(normalizeRole("button")).toBe("button");
  });

  it("collapses single-child non-interactive unlabelled containers and drops empty containers", () => {
    const elementIds = new ElementIds();
    const tree: RawAXTree = {
      window_id: 101,
      root: {
        native_id: "root-panel",
        role: "panel",
        children: [
          {
            native_id: "empty-group",
            role: "group",
            children: [],
          },
          {
            native_id: "nested-filler",
            role: "filler",
            children: [
              {
                native_id: "btn-save",
                role: "button",
                name: "Save",
                actions: ["press"],
                bounds: { x: 10, y: 20, width: 80, height: 24 },
              },
            ],
          },
        ],
      },
    };

    const output = condenseAccessibilityTree(tree, { elementIds, app: "com.apple.TextEdit" });
    expect(output).toBe("[0] button Save [10..90, 20..44]");
    expect(elementIds.resolve("com.apple.TextEdit", 0)?.nativeId).toBe("btn-save");
    expect(elementIds.resolve("com.apple.Safari", 0)).toBeUndefined();
  });

  it("deduplicates non-interactive leaf text children whose text is already in parent", () => {
    const elementIds = new ElementIds();
    const tree: RawAXTree = {
      window_id: 102,
      root: {
        native_id: "btn-submit",
        role: "button",
        name: "Submit Form",
        actions: ["press"],
        bounds: { x: 0, y: 0, width: 100, height: 32 },
        children: [
          {
            native_id: "lbl-submit",
            role: "static",
            name: "Submit",
            children: [],
          },
          {
            native_id: "lbl-form",
            role: "text",
            value: "Form",
            children: [],
          },
        ],
      },
    };

    const output = condenseAccessibilityTree(tree, { elementIds, app: "com.example.App" });
    const lines = output.split("\n");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[0] button Submit Form [0..100, 0..32]");
  });

  it("merges adjacent non-interactive leaf text siblings with spaces", () => {
    const elementIds = new ElementIds();
    const tree: RawAXTree = {
      window_id: 103,
      root: {
        native_id: "dialog",
        role: "window",
        name: "Alert",
        children: [
          {
            native_id: "t1",
            role: "text",
            name: "Hello",
            children: [],
          },
          {
            native_id: "t2",
            role: "static",
            name: "world",
            children: [],
          },
          {
            native_id: "t3",
            role: "label",
            value: "today!",
            children: [],
          },
          {
            native_id: "btn-ok",
            role: "button",
            name: "OK",
            actions: ["press"],
            bounds: { x: 50, y: 50, width: 60, height: 24 },
          },
        ],
      },
    };

    const output = condenseAccessibilityTree(tree, { elementIds, app: "com.example.App" });
    expect(output).toContain("text Hello world today!");
    expect(output).toContain("[0] button OK [50..110, 50..74]");
  });

  it("filters by case-insensitive query and renumbers from zero for that snapshot", () => {
    const elementIds = new ElementIds();
    const tree: RawAXTree = {
      window_id: 104,
      root: {
        native_id: "win",
        role: "window",
        name: "Editor",
        children: [
          {
            native_id: "btn-open",
            role: "button",
            name: "Open File",
            actions: ["press"],
            bounds: { x: 10, y: 10, width: 60, height: 20 },
          },
          {
            native_id: "btn-save",
            role: "button",
            name: "Save Document",
            actions: ["press"],
            bounds: { x: 80, y: 10, width: 60, height: 20 },
          },
          {
            native_id: "btn-export",
            role: "button",
            name: "Export PDF",
            actions: ["press"],
            bounds: { x: 150, y: 10, width: 60, height: 20 },
          },
        ],
      },
    };

    // Full snapshot assigns 0, 1, 2
    const full = condenseAccessibilityTree(tree, { elementIds, app: "com.example.App" });
    expect(full).toContain("[0] button Open File");
    expect(full).toContain("[1] button Save Document");
    expect(full).toContain("[2] button Export PDF");

    // Every snapshot replaces the mapping, so a filtered read numbers its own
    // elements and the indices from the full read no longer resolve.
    const filtered = condenseAccessibilityTree(tree, {
      elementIds,
      app: "com.example.App",
      query: "EXPORT",
    });
    expect(filtered).not.toContain("Open File");
    expect(filtered).not.toContain("Save Document");
    expect(filtered).toContain("[0] button Export PDF");
    expect(elementIds.resolve("com.example.App", 0)?.nativeId).toBe("btn-export");
    expect(elementIds.resolve("com.example.App", 2)).toBeUndefined();
  });

  it("formats states, secondary actions, header metadata, and pushes multiline/>100-char text to the end", () => {
    const elementIds = new ElementIds();
    const longValue = "Line one of a very long document.\nLine two with additional content.";
    const tree: RawAXTree = {
      window_id: 105,
      focused_element: "editor-field",
      selected_text: "Line one",
      selected_elements: ["editor-field"],
      document_text: "Summary doc",
      root: {
        native_id: "editor-field",
        role: "text field",
        name: "Body",
        description: "Main document body",
        value: longValue,
        states: ["focused", "editable", "checkable"],
        actions: ["press", "ShowMenu", "Confirm"],
        bounds: { x: 0, y: 40, width: 400, height: 300 },
      },
    };

    const output = condenseAccessibilityTree(tree, { elementIds, app: "com.example.App" });
    expect(output).toContain("Focused Element: editor-field");
    expect(output).toContain("Selected Text: Line one");
    expect(output).toContain("Selected Elements: editor-field");
    expect(output).toContain("Document Text: Summary doc");

    const lines = output.split("\n");
    const nodeLine = lines[lines.length - 1]!;
    expect(nodeLine).toContain("[0] text field (focused, unchecked, settable)");
    expect(nodeLine).toContain("Secondary Actions: (ShowMenu, Confirm)");
    expect(nodeLine).toContain("[0..400, 40..340]");
    // Multiline value must appear after bounds at the end of the line
    const boundsIdx = nodeLine.indexOf("[0..400, 40..340]");
    const valueIdx = nodeLine.indexOf("Value: Line one of a very long document.\\nLine two");
    expect(boundsIdx).toBeGreaterThan(0);
    expect(valueIdx).toBeGreaterThan(boundsIdx);
  });

  it("produces compact accessibility diffs on repeated calls", () => {
    const prev = "window Editor\n  [0] button Save\n  [1] button Cancel";
    const next = "window Editor\n  [0] button Save (disabled)\n  [1] button Cancel";
    const diff = formatAccessibilityDiff(prev, next);
    expect(diff).toContain("Accessibility diff:");
    expect(diff).toContain("-   [0] button Save");
    expect(diff).toContain("+   [0] button Save (disabled)");
    expect(formatAccessibilityDiff(prev, prev)).toBe("No accessibility changes.");
  });
});

describe("indexed element count", () => {
  const window = (children: RawAXTree["root"][]): RawAXTree => ({
    window_id: 1,
    window_bounds: { x: 100, y: 100, width: 800, height: 600 },
    root: {
      native_id: "1:",
      role: "AXApplication",
      children: [
        {
          native_id: "1:0",
          role: "AXMenuBar",
          children: ["File", "Edit", "View", "Window"].map((name, i) => ({
            native_id: `1:0.${i}`,
            role: "AXMenuBarItem",
            name,
            actions: ["AXPress"],
          })),
        },
        {
          native_id: "1:1",
          role: "AXWindow",
          actions: ["AXRaise"],
          bounds: { x: 0, y: 0, width: 800, height: 600 },
          children: [
            ...["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].map((subrole, i) => ({
              native_id: `1:1.${i}`,
              role: "AXButton",
              subrole,
              actions: ["AXPress"],
            })),
            ...(children as NonNullable<RawAXTree["root"]>[]),
          ],
        },
      ],
    },
  });
  const control = (id: number) => ({
    native_id: `1:1.c${id}`,
    role: "AXButton",
    name: `Tool ${id}`,
    actions: ["AXPress"],
  });

  it("leaves out the menu bar, the window itself, and the window buttons", () => {
    expect(countIndexedElements(window([]))).toBe(0);
  });

  it("counts the controls in the window, and 3 is the first count that is not sparse", () => {
    expect(SPARSE_TREE_ELEMENT_LIMIT).toBe(3);
    expect(countIndexedElements(window([control(1), control(2)]))).toBe(2);
    expect(countIndexedElements(window([control(1), control(2), control(3)]))).toBe(3);
  });

  it("counts nothing for a missing tree", () => {
    expect(countIndexedElements(null)).toBe(0);
    expect(countIndexedElements({ window_id: 0 })).toBe(0);
  });
});

describe("indexed element count with a web area", () => {
  const toolbar = Array.from({ length: 30 }, (_, i) => ({
    native_id: `9:1.t${i}`,
    role: "AXButton",
    name: `Toolbar ${i}`,
    bounds: { x: i * 20, y: 0, width: 18, height: 18 },
    actions: ["AXPress"],
  }));
  const page = (content: NonNullable<RawAXTree["root"]>[]): RawAXTree => ({
    window_id: 1,
    window_bounds: { x: 0, y: 0, width: 1200, height: 800 },
    root: {
      native_id: "9:",
      role: "AXApplication",
      children: [
        {
          native_id: "9:1",
          role: "AXWindow",
          bounds: { x: 0, y: 0, width: 1200, height: 800 },
          children: [
            ...toolbar,
            {
              native_id: "9:1.w0",
              role: "AXWebArea",
              actions: ["AXPress"],
              bounds: { x: 0, y: 80, width: 1200, height: 720 },
              children: content,
            },
            // A small ad frame must not be taken for the page.
            {
              native_id: "9:1.w1",
              role: "AXWebArea",
              bounds: { x: 0, y: 0, width: 100, height: 50 },
              children: [1, 2, 3, 4].map((i) => ({
                native_id: `9:1.w1.${i}`,
                role: "AXLink",
                name: `Ad ${i}`,
                actions: ["AXPress"],
              })),
            },
          ],
        },
      ],
    },
  });

  it("is sparse when the page has one image and no controls, whatever the toolbar holds", () => {
    const tree = page([{ native_id: "9:1.w0.0", role: "AXImage", name: "canvas" }]);
    expect(countIndexedElements(tree)).toBe(0);
    expect(countIndexedElements(tree)).toBeLessThan(SPARSE_TREE_ELEMENT_LIMIT);
  });

  it("is not sparse for a page with links and buttons", () => {
    const tree = page([
      { native_id: "9:1.w0.0", role: "AXLink", name: "Home", actions: ["AXPress"] },
      { native_id: "9:1.w0.1", role: "AXLink", name: "Docs", actions: ["AXPress"] },
      { native_id: "9:1.w0.2", role: "AXButton", name: "Sign in", actions: ["AXPress"] },
    ]);
    expect(countIndexedElements(tree)).toBe(3);
  });

  it("keeps the whole-window rule for a native window without a web area", () => {
    const native: RawAXTree = {
      window_id: 1,
      window_bounds: { x: 0, y: 0, width: 800, height: 600 },
      root: {
        native_id: "4:",
        role: "AXApplication",
        children: [
          {
            native_id: "4:0",
            role: "AXWindow",
            bounds: { x: 0, y: 0, width: 800, height: 600 },
            children: ["Bold", "Italic", "Underline"].map((name, i) => ({
              native_id: `4:0.${i}`,
              role: "AXButton",
              name,
              actions: ["AXPress"],
            })),
          },
        ],
      },
    };
    expect(countIndexedElements(native)).toBe(3);
  });
});

describe("menu bar output", () => {
  const read = (options: { query?: string; includeMenus?: boolean; open?: string } = {}) => {
    const elementIds = new ElementIds();
    const text = condenseAccessibilityTree(browserTree(options.open), {
      elementIds,
      app: "browser",
      ...(options.query ? { query: options.query } : {}),
      ...(options.includeMenus ? { includeMenus: true } : {}),
    });
    return { text, elementIds };
  };

  it("collapses a closed menu to its title and item count", () => {
    const { text } = read();
    expect(text).toMatch(/\[\d+\] AXMenuBarItem Edit \(menu, 34 items\)/);
    expect(text).toMatch(/AXMenuBarItem Help \(menu, 6 items\)/);
    expect(text).not.toContain("Edit item 0");
    expect(text).not.toContain("Smart Quotes");
    // Controls outside the menu bar are untouched.
    expect(text).toContain("AXButton Back");
  });

  it("prints the items of the menu that is open", () => {
    const { text } = read({ open: "Edit" });
    expect(text).toContain("Edit item 0");
    expect(text).toContain("Smart Quotes");
    expect(text).not.toContain("File item 0");
    expect(text).toMatch(/AXMenuBarItem File \(menu, 22 items\)/);
  });

  it("prints every menu with include_menus", () => {
    const { text } = read({ includeMenus: true });
    expect(text).toContain("File item 0");
    expect(text).toContain("Smart Quotes");
    expect(text).not.toContain("(menu,");
  });

  it("finds and indexes a hidden item with a query", () => {
    const { text, elementIds } = read({ query: "Smart Quotes" });
    const line = text.split("\n").find((l) => l.includes("AXMenuItem Smart Quotes"));
    expect(line).toBeDefined();
    const index = Number(/\[(\d+)\]/.exec(line!)?.[1]);
    expect(elementIds.resolve("browser", index)?.nativeId).toBe("9:0.2.m.3");
  });

  it("gives no index to an item it left out", () => {
    const { elementIds } = read();
    const nativeIds = Array.from({ length: 80 }, (_, i) => elementIds.resolve("browser", i)?.nativeId);
    expect(nativeIds).not.toContain("9:0.2.m.3");
    expect(nativeIds).toContain("9:0.2");
  });

  it("cuts the size of a browser's menu bar by an order of magnitude", () => {
    const full = read({ includeMenus: true }).text.length;
    const collapsed = read().text.length;
    expect(collapsed).toBeLessThan(full / 10);
  });
});

describe("menu item marks", () => {
  it("shows a marked menu item as checked and a dash-marked one as mixed", () => {
    const item = (id: string, name: string, states: string[]) => ({
      native_id: id,
      role: "AXMenuItem",
      name,
      states,
      actions: ["AXPress"],
    });
    const tree: RawAXTree = {
      window_id: 1,
      root: {
        native_id: "1:",
        role: "AXMenu",
        children: [
          item("1:0", "Show Toolbar", ["enabled", "checked"]),
          item("1:1", "Show Sidebar", ["enabled"]),
          item("1:2", "Bold", ["enabled", "mixed"]),
        ],
      },
    };
    const text = condenseAccessibilityTree(tree, { elementIds: new ElementIds(), app: "a" });
    expect(text).toContain("AXMenuItem (checked) Show Toolbar");
    expect(text).toContain("AXMenuItem (mixed) Bold");
    expect(text).toMatch(/AXMenuItem Show Sidebar/);
  });
});

describe("open menu detection", () => {
  // `reportsSelected` models an app whose menu bar items send the selected
  // attribute, true or false; without it the field is absent.
  const bar = (
    items: Array<{ name: string; selected?: boolean; framed?: boolean }>,
    reportsSelected = false,
  ): RawAXTree => ({
    window_id: 1,
    root: {
      native_id: "1:",
      role: "AXApplication",
      children: [
        {
          native_id: "1:m",
          role: "AXMenuBar",
          children: items.map((item, i) => ({
            native_id: `1:m.${i}`,
            role: "AXMenuBarItem",
            name: item.name,
            actions: ["AXPress"],
            states: item.selected ? ["enabled", "selected"] : ["enabled"],
            ...(reportsSelected ? { selected: item.selected === true } : {}),
            children: [
              {
                native_id: `1:m.${i}.m`,
                role: "AXMenu",
                ...(item.framed ? { bounds: { x: 10 * i, y: 24, width: 200, height: 300 } } : {}),
                children: [{ native_id: `1:m.${i}.m.0`, role: "AXMenuItem", name: `${item.name} entry`, actions: ["AXPress"] }],
              },
            ],
          })),
        },
      ],
    },
  });
  const text = (tree: RawAXTree) => condenseAccessibilityTree(tree, { elementIds: new ElementIds(), app: "a" });

  it("opens a menu whose bar item is selected", () => {
    const out = text(bar([{ name: "File" }, { name: "Edit", selected: true }]));
    expect(out).toContain("Edit entry");
    expect(out).not.toContain("File entry");
  });

  it("opens a menu that has a frame when the bar item does not say it is selected", () => {
    const out = text(bar([{ name: "File" }, { name: "Edit", framed: true }]));
    expect(out).toContain("Edit entry");
    expect(out).not.toContain("File entry");
  });

  it("ignores frames when every menu has one", () => {
    const out = text(bar([{ name: "File", framed: true }, { name: "Edit", framed: true }]));
    expect(out).not.toContain("entry");
    expect(out).toContain("(menu, 1 items)");
  });

  it("collapses every menu when the items report selected as false, even if a closed menu keeps its frame", () => {
    const out = text(bar([{ name: "File" }, { name: "Edit", framed: true }, { name: "View" }], true));
    expect(out).not.toContain("entry");
    expect(out).toContain("AXMenuBarItem Edit (menu, 1 items)");
  });

  it("opens the selected menu when the items report selected, whatever the frames say", () => {
    const out = text(bar([{ name: "File", framed: true }, { name: "Edit", selected: true }], true));
    expect(out).toContain("Edit entry");
    expect(out).not.toContain("File entry");
  });

  it("falls back to the frame when no item reports selected", () => {
    const out = text(bar([{ name: "File" }, { name: "Edit", framed: true }, { name: "View" }], false));
    expect(out).toContain("Edit entry");
    expect(out).not.toContain("File entry");
    expect(out).not.toContain("View entry");
  });

  it("collapses every menu when none is open", () => {
    expect(text(bar([{ name: "File" }, { name: "Edit" }]))).not.toContain("entry");
  });

  describe("a press on a menu bar item", () => {
    const pressedText = (tree: RawAXTree, pressedMenuBarItem: string) =>
      condenseAccessibilityTree(tree, { elementIds: new ElementIds(), app: "a", pressedMenuBarItem });

    it("opens the pressed menu when no item is selected and it is the only one with a frame", () => {
      const tree = bar([{ name: "File" }, { name: "Edit", framed: true }, { name: "View" }], true);
      const out = pressedText(tree, "1:m.1");
      expect(out).toContain("Edit entry");
      expect(out).not.toContain("File entry");
      expect(out).not.toContain("View entry");
    });

    it("keeps the menu closed when the press was on another item", () => {
      const tree = bar([{ name: "File" }, { name: "Edit", framed: true }, { name: "View" }], true);
      expect(pressedText(tree, "1:m.0")).not.toContain("entry");
    });

    it("keeps the menu closed when more than one menu has a frame", () => {
      const tree = bar([{ name: "File", framed: true }, { name: "Edit", framed: true }], true);
      expect(pressedText(tree, "1:m.1")).not.toContain("entry");
    });

    it("lets a selected item win over the pressed one", () => {
      const tree = bar([{ name: "File", selected: true }, { name: "Edit", framed: true }], true);
      const out = pressedText(tree, "1:m.1");
      expect(out).toContain("File entry");
      expect(out).not.toContain("Edit entry");
    });

    it("does nothing without a press", () => {
      const tree = bar([{ name: "File" }, { name: "Edit", framed: true }], true);
      expect(text(tree)).not.toContain("entry");
    });
  });
});

describe("one window and the other windows", () => {
  const tree = (others: Array<{ id: number; title: string }>): RawAXTree => ({
    window_id: 5,
    window_title: "Canvas 1",
    other_windows: others,
    root: {
      native_id: "7:",
      role: "AXApplication",
      children: [
        {
          native_id: "7:0",
          role: "AXWindow",
          name: "Canvas 1 - Browser",
          window_id: 5,
          children: [{ native_id: "7:0.0", role: "AXButton", name: "Go", actions: ["AXPress"] }],
        },
      ],
    },
  });
  const out = (value: RawAXTree) => condenseAccessibilityTree(value, { elementIds: new ElementIds(), app: "a" });

  it("lists the other windows on one line with ids and no indexes", () => {
    const text = out(tree([{ id: 38214, title: "Canvas 4" }, { id: 37968, title: "VEED" }]));
    expect(text).toContain('Other windows: [38214] "Canvas 4", [37968] "VEED"');
    expect(text.split("\n").filter((line) => line.includes("Other windows"))).toHaveLength(1);
    expect(text).toContain("[0] AXButton Go");
  });

  it("prints no line when the app has one window", () => {
    expect(out(tree([]))).not.toContain("Other windows");
  });

  it("cuts a long list and a long title", () => {
    const many = Array.from({ length: 20 }, (_, i) => ({ id: 100 + i, title: `Tab ${i}` }));
    const text = out(tree(many));
    expect(text).toContain("[111] \"Tab 11\", and 8 more");
    expect(text).not.toContain("Tab 12");
    const long = out(tree([{ id: 9, title: "x".repeat(200) }]));
    expect(long).toContain(`"${"x".repeat(77)}..."`);
  });

  it("finds the window of a sparse count by its id", () => {
    expect(countIndexedElements(tree([]))).toBe(1);
  });

  it("tells when the focused window is none of the windows the read knows", () => {
    const focusedOn = (id: number, extra: Partial<RawAXTree> = {}) => ({
      ...tree([{ id: 6, title: "Mail" }]),
      focused_window: { id, title: "x" },
      ...extra,
    });
    expect(focusedWindowUnlisted(focusedOn(5))).toBe(false);
    expect(focusedWindowUnlisted(focusedOn(6))).toBe(false);
    expect(focusedWindowUnlisted(focusedOn(7))).toBe(true);
    // An address dropdown is left off the list on purpose.
    expect(focusedWindowUnlisted(focusedOn(7, { dropdown_windows: [7] }))).toBe(false);
    expect(focusedWindowUnlisted(tree([]))).toBe(false);
    expect(focusedWindowUnlisted(undefined)).toBe(false);
  });
});
