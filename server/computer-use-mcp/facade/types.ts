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
}

export interface ComputerDriver {
  readonly target: "mac" | "linux" | "windows";
  listApps(): Promise<AppDescriptor[]>;
  listWindows(params?: { app?: string }): Promise<WindowDescriptor[]>;
  getAppState(params: {
    app: string;
    disableDiff?: boolean;
    includeScreenshot?: boolean;
    query?: string;
  }): Promise<DriverAppState>;
  click(params: {
    app: string;
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
    fromX: number;
    fromY: number;
    toX: number;
    toY: number;
    holdKeys?: string[];
  }): Promise<ActionExecutionResult | void>;
  scroll(params: {
    app: string;
    x?: number;
    y?: number;
    elementIndex?: number;
    direction: Direction;
    pages: number;
  }): Promise<ActionExecutionResult | void>;
  pressKey(params: {
    app: string;
    key: string;
    duration?: number;
  }): Promise<ActionExecutionResult | void>;
  typeText(params: {
    app: string;
    text: string;
    elementIndex?: number;
  }): Promise<ActionExecutionResult | void>;
  paste(params: {
    app: string;
    text: string;
    format?: PasteFormat;
  }): Promise<ActionExecutionResult | void>;
  setValue(params: {
    app: string;
    elementIndex: number;
    value: string;
  }): Promise<ActionExecutionResult | void>;
  selectText(params: {
    app: string;
    elementIndex: number;
    text: string;
    prefix?: string;
    suffix?: string;
    selection?: SelectionType;
  }): Promise<ActionExecutionResult | void>;
  performSecondaryAction(params: {
    app: string;
    elementIndex: number;
    action: string;
  }): Promise<ActionExecutionResult | void>;
}
