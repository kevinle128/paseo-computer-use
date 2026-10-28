import type { WaitProbe } from "../wait/types";
import type {
  ActionExecutionResult,
  AppDescriptor,
  Direction,
  MouseButton,
  PasteFormat,
  SelectionType,
  WindowScreenshot,
  WindowDescriptor,
} from "../contract/results";

export interface DriverAppState {
  app: string;
  text: string;
  screenshot: WindowScreenshot | null;
  // The window has too few indexed elements to act on by index. Always false
  // for a query read.
  sparse: boolean;
  // Set when the read asked for it and the driver kept a state from before the
  // app's last action. `summary` is null when nothing differs. `note` is one
  // line of caution for the agent, set when a click may have only activated an
  // app that was in the background.
  change?: { summary: string | null; note?: string };
  // One line when the app's focused window moved to another window than the
  // one the read shows. The read does not follow it.
  focusedWindow?: string;
}

export interface ComputerDriver {
  readonly target: "mac" | "linux" | "windows";
  listApps(): Promise<AppDescriptor[]>;
  listWindows(params?: { app?: string }): Promise<WindowDescriptor[]>;
  getAppState(params: {
    app: string;
    disableDiff?: boolean;
    includeScreenshot?: boolean;
    // Also take a screenshot when the tree is sparse.
    screenshotIfSparse?: boolean;
    query?: string;
    // The window to read. The app's focused window when omitted, except for the
    // read after an action, which keeps the window the action used.
    windowId?: number;
    // Print every menu of the menu bar, not just the open one.
    includeMenus?: boolean;
    // Compare with the state the driver kept before the app's last action and
    // report what changed in `change`.
    reportChange?: boolean;
  }): Promise<DriverAppState>;
  // Runs `run` as one read-only policy call (deny list, abort signal, no
  // control lock) and hands it the probe for reading the app repeatedly.
  waitFor<T>(
    params: { app: string; windowId?: number },
    run: (probe: WaitProbe, signal: AbortSignal | undefined) => Promise<T>,
  ): Promise<T>;
  click(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    x?: number;
    y?: number;
    elementIndex?: number;
    button?: MouseButton;
    clickCount?: number;
    key?: string;
    holdKeys?: string[];
    duration?: number;
  }): Promise<ActionExecutionResult | void>;
  drag(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    fromX: number;
    fromY: number;
    toX: number;
    toY: number;
    holdKeys?: string[];
  }): Promise<ActionExecutionResult | void>;
  scroll(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    x?: number;
    y?: number;
    elementIndex?: number;
    direction: Direction;
    pages: number;
  }): Promise<ActionExecutionResult | void>;
  pressKey(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    key: string;
    duration?: number;
  }): Promise<ActionExecutionResult | void>;
  typeText(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    text: string;
    elementIndex?: number;
  }): Promise<ActionExecutionResult | void>;
  paste(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    text: string;
    elementIndex?: number;
    format?: PasteFormat;
  }): Promise<ActionExecutionResult | void>;
  setValue(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    elementIndex: number;
    value: string;
  }): Promise<ActionExecutionResult | void>;
  selectText(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    elementIndex: number;
    text: string;
    prefix?: string;
    suffix?: string;
    selection?: SelectionType;
  }): Promise<ActionExecutionResult | void>;
  performSecondaryAction(params: {
    app: string;
    // The window to act in. The window of the last read of the app when omitted.
    windowId?: number;
    elementIndex: number;
    action: string;
  }): Promise<ActionExecutionResult | void>;
}
