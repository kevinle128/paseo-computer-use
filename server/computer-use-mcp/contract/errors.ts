// Codes the helper puts on the wire when a command fails. The Swift side
// (HelperError in AXEngine.swift) defines the same strings; keep both lists in
// sync. Only codes that something actually raises belong here.
export const HELPER_ERROR_CODES = [
  "malformed_request",
  "missing_command",
  "unknown_command",
  "internal_error",
  "app_blocked",
  "app_not_found",
  "invalid_app",
  "accessibility_error",
  "aborted_by_user",
  "user_intervened",
  "stale_element",
] as const;

export type HelperErrorCode = (typeof HELPER_ERROR_CODES)[number];

export class ComputerUseError extends Error {
  readonly code: HelperErrorCode;
  readonly request?: unknown;
  readonly requestType?: string;

  constructor(options: {
    code: HelperErrorCode;
    message: string;
    request?: unknown;
    requestType?: string;
  }) {
    super(options.message);
    this.name = "ComputerUseError";
    this.code = options.code;
    this.request = options.request;
    this.requestType = options.requestType;
  }
}

export class ComputerUseTransportError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "ComputerUseTransportError";
  }
}

export const PHYSICAL_ESCAPE_STOP_MESSAGE =
  "Computer Use was stopped by the user with the physical Escape key. Stop your work, do not call further Computer Use tools in this turn, and send a final message noting that the user stopped Computer Use.";

export const USER_INTERVENED_STOP_MESSAGE =
  "Computer Use was paused because the user took control of the mouse pointer. Stop your work, do not call further Computer Use tools in this turn, and send a final message noting that the user took over.";

// Stable codes an agent can branch on. They live only in the TS layer; the
// helper codes above are a separate wire vocabulary and must not gain members
// for plugin-side refusals.
export const TOOL_ERROR_CODES = [
  "computer_use_disabled",
  "computer_busy",
  "aborted_by_user",
  "app_blocked",
  "permission_missing",
  "stale_element",
  "helper_unavailable",
  "invalid_arguments",
  "action_failed",
] as const;

export type ToolErrorCode = (typeof TOOL_ERROR_CODES)[number];

// A refusal decided by the plugin itself (setting off, lock held, app denied).
// It carries its stable code directly so no helper code has to be overloaded.
export class ComputerUseToolError extends Error {
  readonly toolCode: ToolErrorCode;

  constructor(toolCode: ToolErrorCode, message: string) {
    super(message);
    this.name = "ComputerUseToolError";
    this.toolCode = toolCode;
  }
}

export function toToolErrorCode(
  error: unknown,
  options: { targetedElement?: boolean } = {},
): ToolErrorCode {
  if (error instanceof ComputerUseToolError) {
    return error.toolCode;
  }
  if (error instanceof ComputerUseTransportError) {
    return "helper_unavailable";
  }
  if (error instanceof ComputerUseError) {
    if (
      error.code === "aborted_by_user" ||
      error.code === "user_intervened"
    ) {
      return "aborted_by_user";
    }
    // The helper refuses a blocked app after resolving a name to its bundle
    // id, which the plugin cannot do on its own.
    if (error.code === "app_blocked") {
      return "app_blocked";
    }
    // Missing or malformed arguments the helper rejected, such as an unknown
    // key name.
    if (error.code === "malformed_request") {
      return "invalid_arguments";
    }
    // Only a missing or changed element is stale. Any other accessibility
    // failure on a live element (read-only field, refused action) is a real
    // failure, so retrying after a fresh read would not help.
    if (error.code === "stale_element" && options.targetedElement !== false) {
      return "stale_element";
    }
    return "action_failed";
  }
  // Anything else (for example a helper build failure surfaced while starting
  // the helper process) means the helper could not run the command.
  return "helper_unavailable";
}
