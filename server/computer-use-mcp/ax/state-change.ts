import type { RawAXNode, RawAXTree } from "../contract/results";
import { condenseAccessibilityTree } from "./accessibility-tree";
import { ElementIds } from "./element-ids";
import { type AppWindow, appWindows, describeWindow } from "./windows";

// What an action can change that the agent would want to hear about: the
// windows of the app, which window and element have focus, and the content.
export interface StateSnapshot {
  windows: AppWindow[];
  // The window the tree shows.
  windowId: number;
  focus: string | undefined;
  // The content as the agent would see it, with closed menus collapsed.
  printed: string;
  // The same content with every menu item, which is never printed.
  content: string;
}

function findNode(node: RawAXNode | undefined, nativeId: string): RawAXNode | undefined {
  if (!node) return undefined;
  if (node.native_id === nativeId) return node;
  for (const child of node.children ?? []) {
    const found = findNode(child, nativeId);
    if (found) return found;
  }
  return undefined;
}

// Roles whose value moves on its own (progress, busy and level indicators), so
// a change in it says nothing about what an action did.
const ANIMATED_VALUE_ROLES = new Set([
  "AXProgressIndicator",
  "AXBusyIndicator",
  "AXLevelIndicator",
  "AXRelevanceIndicator",
]);

function withoutAnimatedValues(node: RawAXNode): RawAXNode {
  const animated = ANIMATED_VALUE_ROLES.has(node.role);
  const { value: _value, ...rest } = node;
  return {
    ...(animated ? rest : node),
    ...(node.children ? { children: node.children.map(withoutAnimatedValues) } : {}),
  };
}

function animatedValuesRemoved(tree: RawAXTree): RawAXTree {
  return tree.root ? { ...tree, root: withoutAnimatedValues(tree.root) } : tree;
}

export function snapshotOf(fullTree: RawAXTree): StateSnapshot {
  // The list of other windows is compared as windows. Left in the printed
  // text, a title the user's own browsing changes would read as a change of
  // content.
  const { other_windows: _otherWindows, ...tree } = fullTree;
  const focused = tree.focused_element ? findNode(tree.root, tree.focused_element) : undefined;
  return {
    windows: appWindows(fullTree),
    windowId: tree.window_id,
    focus: focused ? [focused.role, focused.name].filter(Boolean).join(" ") : undefined,
    // Numbered with a scratch map, so comparing never touches the agent's
    // indexes. Both texts are compared and never printed.
    printed: condenseAccessibilityTree(animatedValuesRemoved(tree), {
      elementIds: new ElementIds(),
      app: "change",
    }),
    // Menus are included: a menu closes after its item is chosen, and a
    // toggled check mark is the only trace.
    content: condenseAccessibilityTree(animatedValuesRemoved(tree), {
      elementIds: new ElementIds(),
      app: "change",
      includeMenus: true,
    }),
  };
}

// A window is the same window when the ids match; without ids, when the titles do.
const sameWindow = (a: AppWindow, b: AppWindow): boolean =>
  a.id !== undefined && b.id !== undefined ? a.id === b.id : a.title === b.title;

function without(from: AppWindow[], other: AppWindow[]): AppWindow[] {
  const remaining = [...other];
  return from.filter((window) => {
    const at = remaining.findIndex((candidate) => sameWindow(candidate, window));
    if (at === -1) return true;
    remaining.splice(at, 1);
    return false;
  });
}

const shownTitle = (window: AppWindow) => describeWindow({ title: window.title });

// The window the tree shows changed its title (a page loaded, a document was
// renamed). Titles of the app's other windows change on their own and are not
// reported.
function retitled(before: StateSnapshot, after: StateSnapshot): [AppWindow, AppWindow] | undefined {
  if (before.windowId <= 0 || before.windowId !== after.windowId) return undefined;
  const was = before.windows.find((window) => window.id === before.windowId);
  const now = after.windows.find((window) => window.id === after.windowId);
  return was && now && was.title !== now.title ? [was, now] : undefined;
}

// The most lines a change report has. A longer list ends with a count.
const MAX_CHANGE_LINES = 4;

// The differences an action made, one per line, or null when nothing differs.
// Every window that opened or closed and a title change on the window the
// tree shows are listed. When none of those differ, one line follows: focus,
// then printed content, then menu items.
export function describeChange(before: StateSnapshot, after: StateSnapshot): string | null {
  const closed = without(before.windows, after.windows);
  const opened = without(after.windows, before.windows);
  const idsKnown = [...closed, ...opened].every((window) => window.id !== undefined);
  const lines: string[] = [];
  // The same window under a new title is a title change; a window that closed
  // while another opened is both. Without ids the two cannot be told apart.
  if (!idsKnown && closed.length === 1 && opened.length === 1 && before.windowId === after.windowId) {
    lines.push(`title ${shownTitle(closed[0]!)} -> ${shownTitle(opened[0]!)}`);
  } else {
    for (const window of closed) lines.push(`window closed ${describeWindow(window)}`);
    for (const window of opened) lines.push(`window opened ${describeWindow(window)}`);
    const retitle = retitled(before, after);
    if (retitle) {
      lines.push(`title ${shownTitle(retitle[0])} -> ${shownTitle(retitle[1])}`);
    }
  }
  if (lines.length > MAX_CHANGE_LINES) {
    const rest = lines.length - (MAX_CHANGE_LINES - 1);
    lines.splice(MAX_CHANGE_LINES - 1, rest, `and ${rest} more changes`);
  }
  if (lines.length > 0) {
    return lines.join("\n");
  }
  if (before.windowId > 0 && after.windowId > 0 && before.windowId !== after.windowId) {
    return "focus moved to another window";
  }
  if (after.focus !== undefined && after.focus !== before.focus) {
    return `focus moved to ${after.focus}`;
  }
  if (before.printed !== after.printed) {
    return "content";
  }
  // Only items of menus that are not printed differ.
  return before.content !== after.content ? "menu items" : null;
}
