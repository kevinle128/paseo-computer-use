import type { RawAXNode, RawAXTree } from "../contract/results";

// A window of the app as the plugin reports it: the id list_windows shows, when
// the tree gave one, and the title.
export interface AppWindow {
  id?: number;
  title: string;
}

const MAX_TITLE_CHARS = 80;

function shortTitle(title: string): string {
  const flat = title.replaceAll("\r", " ").replaceAll("\n", " ").trim();
  if (flat === "") return "(untitled)";
  return flat.length > MAX_TITLE_CHARS ? `${flat.slice(0, MAX_TITLE_CHARS - 3)}...` : flat;
}

// `[38214] "Canvas 4"`, or `"Canvas 4"` for a window without an id.
export function describeWindow(window: AppWindow): string {
  const title = `"${shortTitle(window.title)}"`;
  return window.id !== undefined && window.id > 0 ? `[${window.id}] ${title}` : title;
}

// How many other windows the Other windows line names before it counts the rest.
const MAX_OTHER_WINDOWS_LISTED = 12;

// The one line that stands for every window of the app that is not read.
export function otherWindowsLine(tree: RawAXTree): string | undefined {
  const others = tree.other_windows ?? [];
  if (others.length === 0) {
    return undefined;
  }
  const listed = others.slice(0, MAX_OTHER_WINDOWS_LISTED).map(describeWindow);
  const rest = others.length - listed.length;
  return `Other windows: ${listed.join(", ")}${rest > 0 ? `, and ${rest} more` : ""}`;
}

function windowNodes(tree: RawAXTree): RawAXNode[] {
  const nodes: RawAXNode[] = [];
  const visit = (node: RawAXNode, depth: number) => {
    if (node.role === "AXWindow") {
      nodes.push(node);
      return;
    }
    if (depth < 2) {
      for (const child of node.children ?? []) {
        visit(child, depth + 1);
      }
    }
  };
  if (tree.root) {
    visit(tree.root, 0);
  }
  return nodes;
}

// Every window a tree knows: the one it shows (and any popup window over it),
// then the others it lists.
export function appWindows(tree: RawAXTree): AppWindow[] {
  const dropdowns = new Set(tree.dropdown_windows ?? []);
  const windows: AppWindow[] = windowNodes(tree)
    .filter((node) => node.window_id === undefined || !dropdowns.has(node.window_id))
    .map((node) => ({
      ...(node.window_id !== undefined ? { id: node.window_id } : {}),
      title: node.name?.trim() ?? "",
    }));
  if (tree.window_id > 0) {
    const shown = windows.find((window) => window.id === tree.window_id) ?? (windows.length === 1 && windows[0]!.id === undefined ? windows[0] : undefined);
    if (shown) {
      shown.id = tree.window_id;
      if (tree.window_title !== undefined) {
        shown.title = tree.window_title;
      }
    }
  }
  for (const other of tree.other_windows ?? []) {
    if (!windows.some((window) => window.id === other.id)) {
      windows.push({ id: other.id, title: other.title });
    }
  }
  return windows;
}

// True when the app's focused window is none of the windows the read knows.
// The helper lists the app's windows before it walks the tree and reads the
// focused window after it, so a window that opened during the walk (Command+n)
// is focused but not listed yet. Only a window on screen is ever reported as
// focused, so the next read lists it.
export function focusedWindowUnlisted(tree: RawAXTree | null | undefined): boolean {
  const focusedId = tree?.focused_window?.id;
  if (!tree || focusedId === undefined || focusedId <= 0) {
    return false;
  }
  if (focusedId === tree.window_id || (tree.dropdown_windows ?? []).includes(focusedId)) {
    return false;
  }
  return !appWindows(tree).some((window) => window.id === focusedId);
}
