import type { RawAXNode, RawAXTree } from "../server/computer-use-mcp/contract/results";

// A menu bar shaped like a large browser's: ten menus, most with a submenu or two.
const MENUS: Record<string, number> = {
  Chrome: 18,
  File: 22,
  Edit: 34,
  View: 16,
  History: 14,
  Bookmarks: 12,
  Profiles: 8,
  Tab: 12,
  Window: 16,
  Help: 6,
};

function menuItem(path: string, name: string, submenuItems: number, marked = false): RawAXNode {
  return {
    native_id: `9:${path}`,
    role: "AXMenuItem",
    name,
    states: ["enabled"],
    actions: ["AXPress"],
    ...(marked ? { menu_mark: "✓" } : {}),
    children:
      submenuItems > 0
        ? [
            {
              native_id: `9:${path}.m`,
              role: "AXMenu",
              children: Array.from({ length: submenuItems }, (_, i) =>
                menuItem(`${path}.m.${i}`, `${name} option ${i}`, 0),
              ),
            },
          ]
        : [],
  } as RawAXNode;
}

export function menuBar(openMenu?: string): RawAXNode {
  return {
    native_id: "9:0",
    role: "AXMenuBar",
    children: Object.entries(MENUS).map(([title, count], index) => ({
      native_id: `9:0.${index}`,
      role: "AXMenuBarItem",
      name: title,
      states: openMenu === title ? ["enabled", "selected"] : ["enabled"],
      actions: ["AXPress"],
      children: [
        {
          native_id: `9:0.${index}.m`,
          role: "AXMenu",
          children: [
            ...Array.from({ length: count }, (_, i) =>
              // Every fourth item opens a submenu of its own.
              menuItem(
                `0.${index}.m.${i}`,
                title === "Edit" && i === 3 ? "Smart Quotes" : `${title} item ${i}`,
                i % 4 === 3 ? 6 : 0,
              ),
            ),
            // A separator has no title and is not counted.
            { native_id: `9:0.${index}.sep`, role: "AXMenuItem", states: ["enabled"] },
          ],
        },
      ],
    })),
  };
}

export function browserTree(openMenu?: string): RawAXTree {
  return {
    window_id: 1,
    window_bounds: { x: 0, y: 0, width: 1200, height: 800 },
    root: {
      native_id: "9:",
      role: "AXApplication",
      name: "Browser",
      children: [
        menuBar(openMenu),
        {
          native_id: "9:1",
          role: "AXWindow",
          name: "Docs",
          bounds: { x: 0, y: 0, width: 1200, height: 800 },
          states: ["enabled"],
          actions: ["AXRaise"],
          children: [
            { native_id: "9:1.0", role: "AXButton", name: "Back", actions: ["AXPress"], states: ["enabled"] },
            { native_id: "9:1.1", role: "AXTextField", name: "Address", value: "https://example.com", states: ["enabled"] },
          ],
        },
      ],
    },
  };
}
