import type { HelperErrorCode } from "./errors";
import type {
  ActionExecutionResult,
  AppDescriptor,
  AppStateResult,
  CaptureSignatureResult,
  Direction,
  ElementExpectation,
  HelperStatusResult,
  MouseButton,
  PasteFormat,
  SelectionType,
  WindowDescriptor,
} from "./results";

// Every command that names or lists apps carries the plugin's block list. The
// helper refuses a command without it, so the plugin stays the one source of
// the list. The prefixes are optional and block every bundle id that starts
// with one of them.
interface AppCommandParams {
  blockedBundleIds: string[];
  blockedBundleIdPrefixes?: string[];
}

// Commands that move the virtual pointer may name the agent in control. The
// helper shows the name next to the pointer and keeps the last one, so an
// older plugin that never sends it still works.
interface PointerCommandParams {
  overlayLabel?: string;
}

// The window an action targets: the one the agent read, or one it named. The
// helper acts on this window or fails with `window_gone`; it never picks
// another window when the named one is closed. Without it the helper uses the
// window of the latest read of the app, then the app's own pick.
interface WindowCommandParams {
  windowId?: number;
}

export interface HelperCommands {
  status: {
    params: Record<string, never>;
    result: HelperStatusResult;
  };
  list_apps: {
    params: AppCommandParams;
    result: AppDescriptor[];
  };
  list_windows: {
    params: AppCommandParams & { app?: string };
    result: WindowDescriptor[];
  };
  get_app_state: {
    params: AppCommandParams & {
      app: string;
      // The window to read. The app's focused window when omitted. A window
      // that is not open fails with `window_gone`.
      windowId?: number;
      includeScreenshot?: boolean;
      // False reads without replacing the helper's element cache and cached
      // window. Every read the agent did not ask for sets it, so an action
      // still resolves against the read the agent saw.
      cache?: boolean;
    };
    result: AppStateResult;
  };
  // A small grayscale thumbnail of one window (or a region of it, in window
  // points) for comparing two moments. The full image never leaves the helper.
  "capture.signature": {
    params: AppCommandParams & {
      app: string;
      // Must belong to `app`. The app's main window when omitted.
      windowId?: number;
      region?: { x: number; y: number; width: number; height: number };
    };
    result: CaptureSignatureResult;
  };
  click: {
    params: AppCommandParams & PointerCommandParams & WindowCommandParams & {
      app: string;
      x?: number;
      y?: number;
      // The only element reference the helper accepts: indices are a
      // plugin-side mapping and are never sent.
      nativeId?: string;
      // Required with nativeId: the element as this agent last saw it.
      expected?: ElementExpectation;
      button?: MouseButton;
      clickCount?: number;
      holdKeys?: string[];
      duration?: number;
    };
    result: ActionExecutionResult;
  };
  drag: {
    params: AppCommandParams & PointerCommandParams & WindowCommandParams & {
      app: string;
      fromX: number;
      fromY: number;
      toX: number;
      toY: number;
      holdKeys?: string[];
    };
    result: ActionExecutionResult;
  };
  scroll: {
    params: AppCommandParams & PointerCommandParams & WindowCommandParams & {
      app: string;
      x?: number;
      y?: number;
      // The only element reference the helper accepts: indices are a
      // plugin-side mapping and are never sent.
      nativeId?: string;
      // Required with nativeId: the element as this agent last saw it.
      expected?: ElementExpectation;
      direction: Direction;
      pages: number;
    };
    result: ActionExecutionResult;
  };
  press_key: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      key: string;
      duration?: number;
    };
    result: ActionExecutionResult;
  };
  type_text: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      text: string;
      // The only element reference the helper accepts: indices are a
      // plugin-side mapping and are never sent.
      nativeId?: string;
      // Required with nativeId: the element as this agent last saw it.
      expected?: ElementExpectation;
      // False (the default) lets the helper paste instead of typing when
      // the input source is an input method such as Telex or VNI.
      allowInputMethod?: boolean;
    };
    result: ActionExecutionResult;
  };
  paste_text: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      text: string;
      format?: PasteFormat;
      // The element to focus before pasting, with the element as this agent
      // last saw it (as for type_text).
      nativeId?: string;
      expected?: ElementExpectation;
    };
    result: ActionExecutionResult;
  };
  set_value: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      nativeId: string;
      expected: ElementExpectation;
      value: string;
    };
    result: ActionExecutionResult;
  };
  select_text: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      nativeId: string;
      expected: ElementExpectation;
      text: string;
      prefix?: string;
      suffix?: string;
      selection?: SelectionType;
    };
    result: ActionExecutionResult;
  };
  perform_secondary_action: {
    params: AppCommandParams & WindowCommandParams & {
      app: string;
      nativeId: string;
      expected: ElementExpectation;
      action: string;
    };
    result: ActionExecutionResult;
  };
  end_turn: {
    params: Record<string, never>;
    result: { ok: true };
  };
  // Stops a queued or running command. `cancelled` is false when the helper
  // has no command with that id (it already finished).
  cancel: {
    params: { requestId: number };
    result: { cancelled: boolean };
  };
  "abort_tap.arm": {
    params: Record<string, never>;
    result: { armed: boolean };
  };
  "abort_tap.disarm": {
    params: Record<string, never>;
    result: { armed: boolean };
  };
}

export type HelperCommandName = keyof HelperCommands;

export interface HelperRequestEnvelope<K extends HelperCommandName = HelperCommandName> {
  id: number;
  cmd: K;
  params: HelperCommands[K]["params"];
  meta?: Record<string, unknown>;
}

export interface HelperResponseEnvelope<T = unknown> {
  id: number;
  ok: boolean;
  result?: T;
  error?: {
    code: HelperErrorCode;
    message: string;
    userFocusChanged?: string;
    // The input idle times behind a focus watch outcome, for the audit log.
    focusWatchDetail?: string;
    // The window a `window_gone` error is about.
    windowId?: number;
    // The bundle id an `app_blocked` error refused.
    bundleId?: string;
    // The rule and input idle times behind a `user_active` refusal, for the audit log.
    userActivityDetail?: string;
  };
}

export type HelperUnsolicitedEvent =
  | {
      event: "abort";
      reason: "escape_key" | "user_intervened";
      message?: string;
    }
  | {
      event: "log";
      level: "info" | "warn" | "error";
      message: string;
    }
  // Emitted by the plugin (never by the helper) when the helper process
  // exits. A new process starts without the Escape tap armed.
  | {
      event: "exited";
      code: number | null;
      signal: string | null;
    };
