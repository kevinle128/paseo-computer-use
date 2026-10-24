import { describe, expect, it } from "vitest";
import {
  condenseAccessibilityTree,
  formatAccessibilityDiff,
  normalizeRole,
} from "../server/computer-use-mcp/ax/accessibility-tree";
import { ElementIds } from "../server/computer-use-mcp/ax/element-ids";
import type { RawAXTree } from "../server/computer-use-mcp/contract/results";

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
