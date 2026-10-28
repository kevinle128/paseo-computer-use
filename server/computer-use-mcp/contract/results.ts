export type Direction = "up" | "down" | "left" | "right" | "u" | "d" | "l" | "r";
export type MouseButton = "left" | "right" | "middle" | "l" | "r" | "m";
export type SelectionType = "text" | "cursor_before" | "cursor_after";
export type PasteFormat = "text" | "md" | "html";

export interface RawAXBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface RawAXNode {
  native_id: string;
  role: string;
  subrole?: string;
  name?: string;
  description?: string;
  value?: string;
  bounds?: RawAXBounds;
  states?: string[];
  // Sent for a menu bar item only, true or false, when the app reports the
  // selected attribute on it; absent when the app does not report it.
  selected?: boolean;
  actions?: string[];
  // The window server id of an AXWindow node.
  window_id?: number;
  children?: RawAXNode[];
  // Set by the condenser on a menu bar item whose menu it left out: how many
  // items the closed menu holds. The helper never sends it.
  menu_items?: number;
}

// The identity of an element as the agent last saw it: role, subrole, name,
// and frame from the raw tree. The helper compares the live element with it.
export interface ElementExpectation {
  role: string;
  subrole?: string;
  name?: string;
  frame?: RawAXBounds;
}

// A window of the app as list_windows shows it.
export interface WindowRef {
  id: number;
  title: string;
}

export interface RawAXTree {
  // The window this tree shows. The tree holds that window and the menu bar,
  // plus any sheet or popup over it, and no other window.
  window_id: number;
  // The title of that window as list_windows shows it, when the window server
  // reports one.
  window_title?: string;
  // The app's other windows (not walked), front to back.
  other_windows?: WindowRef[];
  // Ids of untitled list-only windows under the toolbar (an address
  // suggestion dropdown) that the read did not list. They are not windows
  // that opened or closed for a change report; a walked one keeps its content.
  dropdown_windows?: number[];
  // The app's focused window when the read was made, which may be another
  // window than the one the tree shows.
  focused_window?: WindowRef;
  // The window's frame in screen points. Element bounds are relative to its
  // top-left corner (window-local points), the space action coordinates use.
  window_bounds?: RawAXBounds;
  root?: RawAXNode;
  focused_element?: string;
  selected_text?: string;
  selected_elements?: string[];
  document_text?: string;
}

export interface AppDescriptor {
  id: string;
  bundleIdentifier?: string;
  displayName: string;
  isRunning: boolean;
  lastUsedDate?: string;
  useCount?: number;
  windows?: WindowDescriptor[];
}

export interface WindowDescriptor {
  id: number;
  app: string;
  bundleIdentifier?: string;
  title?: string;
  bounds?: RawAXBounds;
}

export interface WindowScreenshot {
  url: string;
  // Window size in points.
  width?: number;
  height?: number;
  // Image pixels per window point (2 on a Retina display).
  scale?: number;
}

export interface WindowStatePayload {
  text: string;
  screenshot?: WindowScreenshot | null;
  rawTree?: RawAXTree | null;
}

export interface HelperStatusResult {
  osVersion: string;
  axTrusted: boolean;
  screenCaptureGranted: boolean;
  abortTapAvailable: boolean;
  inputSourceId: string;
  isInputMethod: boolean;
  helperSourceHash: string;
}

export interface AppStateResult {
  app: string | { bundleIdentifier: string; displayName: string };
  appSpecificInstructions?: string;
  // Whether the app was the frontmost one when it was read.
  isActive?: boolean;
  windowState: WindowStatePayload;
}

export interface CaptureSignatureResult {
  // Base64 of width * height grayscale bytes, row by row from the top.
  signature: string;
  width: number;
  height: number;
  // The window that was captured, and its size in points.
  windowId: number;
  windowWidth: number;
  windowHeight: number;
}

export interface VerificationResult {
  state: "verified" | "unverified";
  reason?: string;
}

export interface ActionExecutionResult {
  ok: true;
  verification: VerificationResult;
  inputSourceId?: string;
  // How type_text entered the text: keystrokes, or a clipboard paste when
  // the input source is an input method.
  inputPath?: "keys" | "paste";
  // `user_focus_changed: <old> -> <new>` when the app in front of the user's
  // screen was not the same after the action, with `(restored after N ms)`,
  // `(could not restore)`, or `(user switched apps)` when the helper's watch
  // acted on a later change. `user_focus_changed: key focus <old> -> <new>`
  // with `(returned after N ms)` when the user's app stayed in front and the
  // watch gave the keyboard back to the user's window.
  userFocusChanged?: string;
  // The input idle times behind the watch outcome in `userFocusChanged`, and
  // the correction steps that ran (screen hold time, restore path, key focus
  // returned). Kept for the audit log only, so live QA can tell real user
  // input from a false positive; never shown to the agent.
  focusWatchDetail?: string;
}
