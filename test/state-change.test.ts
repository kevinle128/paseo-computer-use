import { describe, expect, it } from "vitest";
import { describeChange, snapshotOf } from "../server/computer-use-mcp/ax/state-change";
import type { RawAXNode, RawAXTree } from "../server/computer-use-mcp/contract/results";

interface Win {
  id: number;
  title: string;
}

const win = (id: number, title: string): Win => ({ id, title });

// The first window is the one the tree shows (unless `windowId` names another
// of them); the rest are listed as other windows, as the helper reports them.
function tree(options: {
  extra?: RawAXNode[];
  windows?: Win[];
  windowId?: number;
  focused?: string;
  field?: string;
}): RawAXTree {
  const windows = options.windows ?? [win(10, "Canvas 0")];
  const shown = windows.find((window) => window.id === options.windowId) ?? windows[0]!;
  return {
    window_id: shown.id,
    window_title: shown.title,
    other_windows: windows.filter((window) => window !== shown),
    ...(options.focused ? { focused_element: options.focused } : {}),
    root: {
      native_id: "3:",
      role: "AXApplication",
      children: [
        {
          native_id: "3:0",
          role: "AXWindow",
          name: `${shown.title} - Browser`,
          window_id: shown.id,
          states: ["enabled"],
          children: [
            { native_id: "3:0.0", role: "AXTextField", name: "Address", value: options.field ?? "", states: ["enabled"] },
            { native_id: "3:0.1", role: "AXButton", name: "Go", actions: ["AXPress"], states: ["enabled"] },
          ],
        },
        ...(options.extra ?? []),
      ],
    },
  };
}

const change = (before: RawAXTree, after: RawAXTree) =>
  describeChange(snapshotOf(before), snapshotOf(after));

describe("describing what an action changed", () => {
  it("reports a window that opened, with its id", () => {
    expect(change(tree({}), tree({ windows: [win(10, "Canvas 0"), win(11, "Settings")] }))).toBe(
      'window opened [11] "Settings"',
    );
  });

  it("reports a window that closed, with its id", () => {
    expect(change(tree({ windows: [win(10, "Canvas 0"), win(11, "Settings")] }), tree({}))).toBe(
      'window closed [11] "Settings"',
    );
  });

  it("reports a title that changed on the window it shows", () => {
    expect(change(tree({}), tree({ windows: [win(10, "Canvas 1")] }))).toBe('title "Canvas 0" -> "Canvas 1"');
  });

  it("does not report a title that changed on another window", () => {
    expect(
      change(tree({ windows: [win(10, "Canvas 0"), win(11, "Mail")] }), tree({ windows: [win(10, "Canvas 0"), win(11, "Mail (2)")] })),
    ).toBeNull();
  });

  it("reports a window that closed and another that opened, one per line", () => {
    expect(change(tree({}), tree({ windows: [win(11, "Canvas 1")] }))).toBe(
      'window closed [10] "Canvas 0"\nwindow opened [11] "Canvas 1"',
    );
  });

  it("reports a title change next to a window that closed", () => {
    // A Return that navigates also closes the address suggestions popup.
    expect(
      change(tree({ windows: [win(10, "Canvas 3"), win(11, "Suggestions")] }), tree({ windows: [win(10, "Canvas 0")] })),
    ).toBe('window closed [11] "Suggestions"\ntitle "Canvas 3" -> "Canvas 0"');
  });

  it("lists at most four lines and counts the rest", () => {
    const many = [win(10, "Canvas 0"), win(21, "A"), win(22, "B"), win(23, "C"), win(24, "D"), win(25, "E")];
    expect(change(tree({ windows: many }), tree({ windows: [win(10, "Canvas 1")] }))).toBe(
      'window closed [21] "A"\nwindow closed [22] "B"\nwindow closed [23] "C"\nand 3 more changes',
    );
  });

  it("reports a title change by itself and a window change without a focus line", () => {
    expect(
      change(tree({ focused: "3:0.0" }), tree({ windows: [win(10, "Canvas 0"), win(11, "Settings")], focused: "3:0.1" })),
    ).toBe('window opened [11] "Settings"');
  });

  it("matches windows by title when the tree has no ids", () => {
    const legacy = (titles: string[]): RawAXTree => ({
      window_id: 0,
      root: {
        native_id: "3:",
        role: "AXApplication",
        children: titles.map((title, i) => ({ native_id: `3:${i}`, role: "AXWindow", name: title })),
      },
    });
    expect(change(legacy(["A"]), legacy(["A", "B"]))).toBe('window opened "B"');
    expect(change(legacy(["A", "B"]), legacy(["A"]))).toBe('window closed "B"');
  });

  it("reports menu items when only a menu that is not printed differs", () => {
    const menuBar = (states: string[]): RawAXNode => ({
      native_id: "3:m",
      role: "AXMenuBar",
      children: [
        {
          native_id: "3:m.0",
          role: "AXMenuBarItem",
          name: "View",
          actions: ["AXPress"],
          children: [
            {
              native_id: "3:m.0.m",
              role: "AXMenu",
              children: [{ native_id: "3:m.0.m.0", role: "AXMenuItem", name: "Show Toolbar", states, actions: ["AXPress"] }],
            },
          ],
        },
      ],
    });
    expect(change(tree({ extra: [menuBar(["enabled"])] }), tree({ extra: [menuBar(["enabled", "checked"])] }))).toBe(
      "menu items",
    );
  });

  it("reports content when the menu that differs is the open one", () => {
    const menuBar = (states: string[]): RawAXNode => ({
      native_id: "3:m",
      role: "AXMenuBar",
      children: [
        {
          native_id: "3:m.0",
          role: "AXMenuBarItem",
          name: "View",
          states: ["selected"],
          actions: ["AXPress"],
          children: [
            {
              native_id: "3:m.0.m",
              role: "AXMenu",
              children: [{ native_id: "3:m.0.m.0", role: "AXMenuItem", name: "Show Toolbar", states, actions: ["AXPress"] }],
            },
          ],
        },
      ],
    });
    expect(change(tree({ extra: [menuBar(["enabled"])] }), tree({ extra: [menuBar(["enabled", "checked"])] }))).toBe(
      "content",
    );
  });

  it("ignores a value that moves on its own", () => {
    const progress = (value: string): RawAXNode => ({
      native_id: "3:p",
      role: "AXProgressIndicator",
      name: "Copying",
      value,
      states: ["enabled"],
    });
    expect(change(tree({ extra: [progress("10")] }), tree({ extra: [progress("55")] }))).toBeNull();
    // A real change next to it is still seen.
    expect(change(tree({ extra: [progress("10")], field: "a" }), tree({ extra: [progress("55")], field: "b" }))).toBe(
      "content",
    );
  });

  it("does not report a walked suggestion dropdown as a window that opened or closed", () => {
    const dropdown = (): RawAXNode => ({
      native_id: "3:1",
      role: "AXWindow",
      name: "",
      window_id: 11,
      states: ["enabled"],
      children: [{ native_id: "3:1.0", role: "AXList", name: "", states: ["enabled"] }],
    });
    const withDropdown = { ...tree({ extra: [dropdown()] }), dropdown_windows: [11] };
    const windowLines = (text: string | null) => (text ?? "").split("\n").filter((line) => line.startsWith("window "));
    expect(windowLines(change(tree({}), withDropdown))).toEqual([]);
    expect(windowLines(change(withDropdown, tree({})))).toEqual([]);
    // The same untitled window, when the helper did not mark it, is still reported.
    const unmarked = tree({ extra: [dropdown()] });
    expect(windowLines(change(tree({}), unmarked))).toEqual(['window opened [11] "(untitled)"']);
  });

  it("names an untitled window", () => {
    expect(change(tree({}), tree({ windows: [win(10, "Canvas 0"), win(11, "")] }))).toBe(
      'window opened [11] "(untitled)"',
    );
  });

  it("reports focus moving to another window", () => {
    const windows = [win(10, "Canvas 0"), win(11, "Canvas 1")];
    expect(change(tree({ windows, windowId: 10 }), tree({ windows, windowId: 11 }))).toBe("focus moved to another window");
  });

  it("reports focus moving to an element, by role and name", () => {
    expect(change(tree({ focused: "3:0.0" }), tree({ focused: "3:0.1" }))).toBe("focus moved to AXButton Go");
  });

  it("reports changed content when nothing more specific differs", () => {
    expect(change(tree({ field: "a" }), tree({ field: "b" }))).toBe("content");
  });

  it("reports nothing when the states are the same", () => {
    expect(change(tree({ focused: "3:0.0", field: "a" }), tree({ focused: "3:0.0", field: "a" }))).toBeNull();
  });

  it("prefers a window change over a focus or content change", () => {
    expect(
      change(tree({ focused: "3:0.0" }), tree({ windows: [win(10, "Canvas 0"), win(11, "Settings")], focused: "3:0.1", field: "x" })),
    ).toBe('window opened [11] "Settings"');
  });
});
