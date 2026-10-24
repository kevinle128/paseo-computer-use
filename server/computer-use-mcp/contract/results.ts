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
  actions?: string[];
  children?: RawAXNode[];
}

// The identity of an element as the agent last saw it: role, subrole, name,
// and frame from the raw tree. The helper compares the live element with it.
export interface ElementExpectation {
  role: string;
  subrole?: string;
  name?: string;
  frame?: RawAXBounds;
}

export interface RawAXTree {
  window_id: number;
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
  windowState: WindowStatePayload;
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
}
