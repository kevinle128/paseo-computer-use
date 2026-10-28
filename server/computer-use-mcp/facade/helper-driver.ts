import { setTimeout as sleep } from "node:timers/promises";
import {
  condenseAccessibilityTree,
  countIndexedElements,
  formatAccessibilityDiff,
  NO_CHANGES_TEXT,
  SPARSE_TREE_ELEMENT_LIMIT,
} from "../ax/accessibility-tree";
import { ElementIds, type IndexedElement } from "../ax/element-ids";
import { describeChange, snapshotOf, type StateSnapshot } from "../ax/state-change";
import { describeWindow, focusedWindowUnlisted } from "../ax/windows";
import { ComputerUseError, ComputerUseToolError } from "../contract/errors";
import type { HelperPort } from "../contract/helper-port";
import type { ActionExecutionResult, WindowScreenshot } from "../contract/results";
import {
  asBrowserRefusal,
  BROWSER_BUNDLE_IDS,
  blockedBundleIds,
  WEB_APP_BUNDLE_ID_PREFIXES,
  type PolicyEngineConfig,
  withComputerUsePolicy,
} from "../policy";
import type { AuditDetail } from "../policy/audit";
import { ActionSettler } from "../runtime/action-settler";
import {
  decodeSignature,
  PRE_ACTION_BASELINE_MAX_AGE_MS,
  type PreActionBaseline,
  type SignatureCapture,
} from "../wait/signature";
import type { WaitProbe } from "../wait/types";
import type { ComputerDriver, DriverAppState } from "./types";

// The helper types one UTF-16 unit about every 10 ms, so a flat request
// timeout would cut off long text part way through. The budget keeps the usual
// 30 s for short text and adds 30 ms per unit, three times the measured pace.
// Escape and Paseo Stop still end the command at once through the abort signal.
export function typeTextTimeoutMs(text: string): number {
  return 30_000 + text.length * 30;
}

// The tree and every action tool use window points. The screenshot is in
// pixels, `scale` pixels per point (2 on a Retina display), so a position read
// off the image must be divided by the scale before it is used in an action.
export function screenshotCoordinateNote(screenshot: WindowScreenshot): string {
  const scale =
    screenshot.scale !== undefined && Number.isFinite(screenshot.scale) && screenshot.scale > 0
      ? screenshot.scale
      : 1;
  const rounded = Math.round(scale * 100) / 100;
  const size =
    screenshot.width !== undefined && screenshot.height !== undefined
      ? `${Math.round(screenshot.width * scale)}x${Math.round(screenshot.height * scale)} pixels for a ${screenshot.width}x${screenshot.height} point window`
      : `scale ${rounded}`;
  if (rounded === 1) {
    return `Screenshot: ${size}. Screenshot pixels equal window points, the coordinates the tree and action tools use.`;
  }
  return `Screenshot: ${size}. The tree and action tools use window points: divide a screenshot pixel position by ${rounded}.`;
}

type GetAppStateParams = Parameters<ComputerDriver["getAppState"]>[0];

// How often, and how far apart, the read after an action is made again while
// the app's focused window is not among the windows it lists: about 300 ms.
const NEW_WINDOW_REREADS = 3;
const NEW_WINDOW_REREAD_INTERVAL_MS = 100;

// What the agent reads when it acts on an app again after a `user_active`
// refusal without reading the app first.
export const STALE_STATE_MESSAGE =
  "The app may have changed while the user was working. Call get_app_state, then retry.";

const INACTIVE_APP_CLICK_NOTE =
  "The app was not active; this click may only have activated its window. If nothing happened, click again.";

// A click on an app that was in the background may only bring its window to
// the front. Said only when the app went from inactive to active with the click
// and the click changed nothing but focus or menus. The plugin acts without
// raising windows, so an app that stays inactive says nothing, and a sparse
// app shows no change in its tree whatever the click did.
function inactiveClickNote(
  before: { tool: string; wasActive?: boolean },
  summary: string | null,
  nowActive: boolean | undefined,
  sparse: boolean,
): string | undefined {
  const onlyActivation =
    summary === null ||
    summary === "menu items" ||
    summary.split("\n").every((line) => line.startsWith("focus moved"));
  return before.tool === "click" &&
    before.wasActive === false &&
    nowActive === true &&
    !sparse &&
    onlyActivation
    ? INACTIVE_APP_CLICK_NOTE
    : undefined;
}

export interface CreateHelperDriverOptions {
  helperPort: HelperPort;
  policy?: PolicyEngineConfig;
  elementIds?: ElementIds;
  actionSettler?: ActionSettler;
  // The agent name the helper shows next to the virtual pointer.
  overlayLabel?: string;
  // Milliseconds on a monotonic clock; tests pass a fake one.
  now?: () => number;
  getCallerContext?: () => {
    callerId: string;
    agentId?: string | null;
  };
}

// What the helper says when the element a text action named did not take the
// focus. It never sees indices, so the plugin adds the one the agent used.
const ELEMENT_NOT_FOCUSED_REASON = "could not focus element";

function withElementIndex<T extends ActionExecutionResult>(result: T, elementIndex: number | undefined): T {
  if (
    elementIndex === undefined ||
    result.verification.state !== "unverified" ||
    result.verification.reason !== ELEMENT_NOT_FOCUSED_REASON
  ) {
    return result;
  }
  return { ...result, verification: { ...result.verification, reason: `${ELEMENT_NOT_FOCUSED_REASON} [${elementIndex}]` } };
}

export function createHelperDriver(options: CreateHelperDriverOptions): ComputerDriver & {
  resetSessionState(): void;
  readonly elementIds: ElementIds;
  readonly actionSettler: ActionSettler;
} {
  const { policy } = options;
  const elementIds = options.elementIds ?? new ElementIds();
  const actionSettler = options.actionSettler ?? new ActionSettler(100);
  // The last text the model received for each app (from a full or a query
  // read) and the index numbering that text used.
  const previousStateByApp = new Map<string, { text: string; mappingKey: string }>();
  const seenAppInstructions = new Set<string>();
  const now = options.now ?? (() => performance.now());
  // Whether the last full read of each app found a sparse tree.
  const sparseByApp = new Map<string, boolean>();
  // The window the agent's last full read showed, so the pre-action image
  // is of that window and not of whatever the helper would pick now.
  const readWindowByApp = new Map<string, number>();
  // The focused window of each app as of the last read, to tell when an action
  // moved the app's focus to another window.
  const focusedWindowByApp = new Map<string, number | undefined>();
  // The element the action in progress pressed, for the menu bar rule of the
  // read after it.
  const pressedElementByApp = new Map<string, string>();
  // The app as it was just before its last action, for the actions whose
  // result the helper cannot check, with the tool that acted and whether the
  // app was in front. The read after the action consumes it.
  const stateBeforeActionByApp = new Map<string, { snapshot: StateSnapshot; tool: string; wasActive?: boolean }>();
  // The window image just before each app's last action, kept only for apps
  // with a sparse tree: their changes show on screen and not in the tree.
  const baselineByApp = new Map<string, { baseline: PreActionBaseline; atMs: number }>();
  // The app string an agent passes ("TextEdit", "com.apple.TextEdit") mapped
  // to the bundle id the helper resolved it to on the last get_app_state.
  // Element indices are looked up by that bundle id only.
  const canonicalAppByRequest = new Map<string, string>();
  // The bundle id an app string resolved to on the last read, else the string.
  const canonicalOf = (app: string): string => canonicalAppByRequest.get(app) ?? app;
  // Apps whose action the helper refused because the user was using the
  // computer, keyed by the app string of that action. The value orders the
  // refusal against the agent's reads: only a get_app_state that started
  // after the refusal clears it.
  const userActiveRefusalByApp = new Map<string, number>();
  let activitySeq = 0;

  // The user may have changed the app while the action was refused, so the
  // agent's numbering and the state kept for the refused action are not
  // trusted until the agent reads the app again.
  const rememberUserActive = (app: string): void => {
    userActiveRefusalByApp.set(app, ++activitySeq);
    const canonicalApp = canonicalOf(app);
    stateBeforeActionByApp.delete(canonicalApp);
    pressedElementByApp.delete(canonicalApp);
    baselineByApp.delete(canonicalApp);
  };

  const assertReadSinceUserActive = (app: string): void => {
    const canonicalApp = canonicalOf(app);
    for (const key of userActiveRefusalByApp.keys()) {
      if (canonicalOf(key) === canonicalApp) {
        throw new ComputerUseToolError("stale_state", STALE_STATE_MESSAGE);
      }
    }
  };

  const clearUserActive = (canonicalApp: string, readSeq: number): void => {
    for (const [key, refusedAt] of userActiveRefusalByApp) {
      if (canonicalOf(key) === canonicalApp && refusedAt < readSeq) {
        userActiveRefusalByApp.delete(key);
      }
    }
  };

  // Turns a model-facing index into the helper's native id and the element as
  // this agent saw it, or refuses with stale_element. There is no fallback to
  // another app or an older snapshot.
  const resolveElement = (app: string, elementIndex: number, windowId?: number): IndexedElement => {
    const canonicalApp = canonicalAppByRequest.get(app);
    const readWindow = canonicalApp !== undefined ? readWindowByApp.get(canonicalApp) : undefined;
    if (windowId !== undefined && readWindow !== undefined && windowId !== readWindow) {
      throw new ComputerUseToolError(
        "stale_element",
        `Element indexes come from your read of window ${readWindow}, not window ${windowId}. Call get_app_state with window_id ${windowId} first.`,
      );
    }
    if (canonicalApp === undefined) {
      throw new ComputerUseToolError(
        "stale_element",
        `No accessibility snapshot for '${app}'. Call get_app_state for this app first.`,
      );
    }
    const element = elementIds.resolve(canonicalApp, elementIndex);
    if (element === undefined) {
      throw new ComputerUseToolError(
        "stale_element",
        `Element index ${elementIndex} is not in the latest get_app_state result for '${app}'. Call get_app_state again.`,
      );
    }
    return element;
  };

  // Read on every call so a change to the user's extra blocked apps applies
  // to the next command. The list commands get only these apps, so browsers
  // stay listed.
  const deniedForLists = (): string[] => blockedBundleIds(policy?.getExtraBlockedBundleIds?.());
  // Every app command also carries the browsers and the browser web app
  // prefixes while browsers are not allowed, so the helper refuses a partial
  // name that resolves to one.
  const blocked = (): { blockedBundleIds: string[]; blockedBundleIdPrefixes?: string[] } =>
    policy?.allowBrowserApps() === true
      ? { blockedBundleIds: deniedForLists() }
      : {
          blockedBundleIds: [...deniedForLists(), ...BROWSER_BUNDLE_IDS],
          blockedBundleIdPrefixes: [...WEB_APP_BUNDLE_ID_PREFIXES],
        };

  // The helper's refusal of a browser reaches the agent as use_browser_tools,
  // from every command, a wait's probe included.
  const helperPort: Pick<HelperPort, "request"> = {
    request: (cmd, params, requestOptions) =>
      options.helperPort.request(cmd, params, requestOptions).catch((error: unknown) => {
        throw asBrowserRefusal(error, deniedForLists());
      }),
  };

  // The agent an action is for. The helper keeps it with the focus watch of
  // the action, so a restore note reaches that agent and no other.
  const actionMeta = () => ({ meta: { callerId: getContext().callerId } });

  const pointerLabel = options.overlayLabel ? { overlayLabel: options.overlayLabel } : {};

  const optionalElement = (app: string, elementIndex: number | undefined, windowId?: number) =>
    elementIndex === undefined ? {} : resolveElement(app, elementIndex, windowId);

  // The window an action or a read in the background uses: the one the agent
  // named, else the window of the agent's last read of the app. Never a window
  // the app picked later. Unknown until the agent has read the app.
  const targetWindow = (app: string, windowId?: number): number | undefined => {
    if (windowId !== undefined) {
      return windowId;
    }
    const canonicalApp = canonicalAppByRequest.get(app);
    return canonicalApp !== undefined ? readWindowByApp.get(canonicalApp) : undefined;
  };

  const windowParam = (app: string, windowId?: number): { windowId?: number } => {
    const target = targetWindow(app, windowId);
    return target !== undefined ? { windowId: target } : {};
  };

  // Remembers which element this action pressed. Only its identity is kept;
  // the read after the action decides what it means.
  const pressed = <T extends { nativeId?: string }>(app: string, element: T): T => {
    const canonicalApp = canonicalAppByRequest.get(app);
    if (canonicalApp !== undefined && element.nativeId !== undefined) {
      pressedElementByApp.set(canonicalApp, element.nativeId);
    }
    return element;
  };

  const getContext = () =>
    options.getCallerContext?.() ?? {
      callerId: "default",
      agentId: null,
    };

  const requestSignature = async (
    app: string,
    params: { windowId?: number; region?: { x: number; y: number; width: number; height: number } },
    signal: AbortSignal | undefined,
    timeoutMs: number,
  ): Promise<SignatureCapture> => {
    const res = await helperPort.request(
      "capture.signature",
      {
        app,
        ...blocked(),
        ...(params.windowId !== undefined ? { windowId: params.windowId } : {}),
        ...(params.region ? { region: params.region } : {}),
      },
      { signal, timeoutMs },
    );
    return {
      bytes: decodeSignature(res.signature),
      windowId: res.windowId,
      windowWidth: res.windowWidth,
      windowHeight: res.windowHeight,
    };
  };

  // How long an image read before an action may take. The action waits for it.
  const BASELINE_CAPTURE_TIMEOUT_MS = 2_000;

  // Before an action in an app whose last read was sparse, remember how the
  // window looks, so a later wait can tell what the action changed. Any
  // failure (no Screen Recording permission, no window) only means no baseline.
  const recordBaseline = async (
    app: string,
    windowId: number | undefined,
    signal: AbortSignal | undefined,
  ): Promise<void> => {
    const canonicalApp = canonicalAppByRequest.get(app);
    if (canonicalApp === undefined || sparseByApp.get(canonicalApp) !== true) {
      return;
    }
    try {
      const baseline = await requestSignature(
        app,
        windowId !== undefined ? { windowId } : {},
        signal,
        BASELINE_CAPTURE_TIMEOUT_MS,
      );
      baselineByApp.set(canonicalApp, { baseline, atMs: now() });
    } catch {
      baselineByApp.delete(canonicalApp);
    }
  };

  // How long the read before an action may take. It costs the same as the read
  // after the action, once per click, drag, scroll, key press, or secondary
  // action; other actions check their own result and skip it.
  const BEFORE_ACTION_READ_TIMEOUT_MS = 1_500;

  const recordStateBeforeAction = async (
    app: string,
    windowId: number | undefined,
    tool: string,
    signal: AbortSignal | undefined,
  ): Promise<void> => {
    // Without an earlier read there is no app to compare, and this read must
    // not decide which app a name means.
    const canonicalApp = canonicalAppByRequest.get(app);
    if (canonicalApp === undefined) {
      return;
    }
    try {
      const res = await requestAppState(app, false, signal, BEFORE_ACTION_READ_TIMEOUT_MS, false, windowId);
      const tree = res.windowState?.rawTree;
      if (tree) {
        focusedWindowByApp.set(canonicalApp, tree.focused_window?.id);
        stateBeforeActionByApp.set(canonicalApp, {
          snapshot: snapshotOf(tree),
          tool,
          ...(res.isActive !== undefined ? { wasActive: res.isActive } : {}),
        });
      }
    } catch {
      // No before state: the action's own result stands.
    }
  };

  const runWithPolicy = async <TInput extends { app?: string; windowId?: number }, TResult>(
    toolName: string,
    input: TInput,
    extra: { mutating: boolean; textLength?: number; reportsChange?: boolean; listing?: boolean },
    run: (resolvedInput: TInput, opts: { signal?: AbortSignal }) => Promise<TResult>,
  ): Promise<TResult> => {
    const auditDetail: AuditDetail = {};
    const fn: typeof run = async (resolved, opts) => {
      if (extra.mutating && resolved.app) {
        // Checked before the reads below, so a refused action reads nothing.
        assertReadSinceUserActive(resolved.app);
        // A state kept for an earlier action never describes this one.
        const known = canonicalAppByRequest.get(resolved.app);
        if (known !== undefined) {
          stateBeforeActionByApp.delete(known);
          pressedElementByApp.delete(known);
        }
        const windowId = targetWindow(resolved.app, resolved.windowId);
        await recordBaseline(resolved.app, windowId, opts.signal);
        if (extra.reportsChange) {
          await recordStateBeforeAction(resolved.app, windowId, toolName, opts.signal);
        }
      }
      let result: TResult;
      try {
        result = await run(resolved, opts);
      } catch (error) {
        // An action that changed the app in front and then failed has no
        // result to carry the line; the audit entry still records it.
        if (error instanceof ComputerUseError) {
          if (error.userFocusChanged !== undefined) {
            auditDetail.userFocusChanged = error.userFocusChanged;
          }
          if (error.focusWatchDetail !== undefined) {
            auditDetail.focusWatchDetail = error.focusWatchDetail;
          }
          if (error.code === "user_active" && extra.mutating && resolved.app) {
            rememberUserActive(resolved.app);
            if (error.userActivityDetail !== undefined) {
              auditDetail.userActivityDetail = error.userActivityDetail;
            }
          }
        }
        throw error;
      }
      const reported = result as { userFocusChanged?: unknown; focusWatchDetail?: unknown } | null | undefined;
      if (typeof reported?.userFocusChanged === "string") {
        auditDetail.userFocusChanged = reported.userFocusChanged;
      }
      if (typeof reported?.focusWatchDetail === "string") {
        auditDetail.focusWatchDetail = reported.focusWatchDetail;
      }
      return result;
    };
    if (!policy) {
      return fn(input, {});
    }
    const caller = getContext();
    return withComputerUsePolicy(
      policy,
      {
        callerId: caller.callerId,
        agentId: caller.agentId,
        toolName,
        mutating: extra.mutating,
        app: input.app,
        ...(extra.listing ? { listing: true } : {}),
        textLength: extra.textLength,
        auditDetail,
      },
      input,
      (resolved, { signal }) => fn(resolved, { signal }),
    );
  };

  // The helper always returns the whole raw tree, so every read of an app
  // goes through here.
  const requestAppState = (
    app: string,
    includeScreenshot: boolean | undefined,
    signal?: AbortSignal,
    timeoutMs?: number,
    // True only for a read the agent asked for.
    agentRead = false,
    windowId?: number,
  ) =>
    helperPort.request(
      "get_app_state",
      // Query filtering and diffing happen on the plugin's own numbered text.
      {
        app,
        includeScreenshot,
        ...blocked(),
        ...(agentRead ? {} : { cache: false }),
        ...(windowId !== undefined ? { windowId } : {}),
      },
      { signal, ...(timeoutMs !== undefined ? { timeoutMs } : {}) },
    );

  const rememberCanonicalApp = (
    requested: string,
    app: string | { bundleIdentifier: string; displayName: string },
  ): string => {
    const canonicalApp =
      typeof app === "string" ? app : app.bundleIdentifier || app.displayName || requested;
    canonicalAppByRequest.set(requested, canonicalApp);
    canonicalAppByRequest.set(canonicalApp, canonicalApp);
    return canonicalApp;
  };

  // The read after an action found the window the action used closed (the
  // action closed it, or the user did). Nothing else is read in its place: the
  // agent picks the next window with get_app_state.
  const windowGoneState = (app: string, windowId: number): DriverAppState => {
    const canonicalApp = canonicalAppByRequest.get(app) ?? app;
    const before = stateBeforeActionByApp.get(canonicalApp);
    stateBeforeActionByApp.delete(canonicalApp);
    pressedElementByApp.delete(canonicalApp);
    // The last text the agent received shows the window that is now closed.
    // A diff of the next read with it would list that window again on its
    // before side, so the next read prints the full state.
    previousStateByApp.delete(canonicalApp);
    const title = before?.snapshot.windows.find((window) => window.id === windowId)?.title;
    const closed = title !== undefined ? describeWindow({ id: windowId, title }) : `[${windowId}]`;
    return {
      app: canonicalApp,
      text: `Window ${closed} is closed. Call get_app_state to read a window that is open.`,
      screenshot: null,
      sparse: false,
      change: { summary: `window closed ${closed}` },
    };
  };

  // One read of an app for getAppState: the tree, the numbering, the diff
  // with the last text the agent received, and for the read after an action
  // what changed.
  const readAppState = async (
    resolved: GetAppStateParams,
    requestedWindow: number | undefined,
    signal: AbortSignal | undefined,
  ): Promise<DriverAppState> => {
    let res = await requestAppState(resolved.app, resolved.includeScreenshot, signal, undefined, true, requestedWindow);
    // A window the action opened can be focused before it is listed. Read
    // again, a bounded number of times, so the change and the Other windows
    // line name it.
    for (let retry = 0; resolved.reportChange && retry < NEW_WINDOW_REREADS && focusedWindowUnlisted(res.windowState?.rawTree); retry++) {
      await sleep(NEW_WINDOW_REREAD_INTERVAL_MS, undefined, signal ? { signal } : {});
      res = await requestAppState(resolved.app, resolved.includeScreenshot, signal, undefined, true, requestedWindow);
    }
    const canonicalApp = rememberCanonicalApp(resolved.app, res.app);

    // The read after an action (`reportChange`) belongs to that action
    // and keeps its baseline. A read the agent asked for shows the
    // window as it is now, so a later wait must compare with that and
    // not with the window from before the action.
    if (!resolved.reportChange) {
      baselineByApp.delete(canonicalApp);
    }

    // A query read numbers only the filtered elements, so its count
    // says nothing about how sparse the window is.
    const sparse =
      !resolved.query &&
      countIndexedElements(res.windowState?.rawTree) < SPARSE_TREE_ELEMENT_LIMIT;
    if (!resolved.query) {
      sparseByApp.set(canonicalApp, sparse);
    }
    // Every read the agent asked for numbers and caches the elements of
    // one window, and that window is where its actions go from now on.
    const readWindowId = res.windowState?.rawTree?.window_id;
    if (readWindowId !== undefined && readWindowId > 0) {
      readWindowByApp.set(canonicalApp, readWindowId);
    } else {
      readWindowByApp.delete(canonicalApp);
    }
    let screenshot = res.windowState?.screenshot ?? null;
    if (sparse && resolved.screenshotIfSparse && screenshot === null) {
      // The tree came back without an image. Ask again for the image
      // alone: reading the tree twice is cheap for a sparse tree, and
      // this is the only read that updates the numbering and the diff.
      const withImage = await requestAppState(
        resolved.app,
        true,
        signal,
        undefined,
        false,
        readWindowId !== undefined && readWindowId > 0 ? readWindowId : undefined,
      );
      screenshot = withImage.windowState?.screenshot ?? null;
    }

    // What the action pressed and the state before it belong to the read
    // after the action and no other.
    const before = resolved.reportChange ? stateBeforeActionByApp.get(canonicalApp) : undefined;
    const pressed = resolved.reportChange ? pressedElementByApp.get(canonicalApp) : undefined;
    if (resolved.reportChange) {
      stateBeforeActionByApp.delete(canonicalApp);
      pressedElementByApp.delete(canonicalApp);
    }

    // Only the helper's header line is kept. Element lines always come
    // from the condensed tree, whose indices are the ones the plugin
    // can resolve; any numbered text from the helper is ignored.
    const helperHeader = (res.windowState?.text ?? "").split("\n", 1)[0] ?? "";
    const condensed = condenseAccessibilityTree(res.windowState?.rawTree, {
      elementIds,
      query: resolved.query,
      app: canonicalApp,
      ...(resolved.includeMenus ? { includeMenus: true } : {}),
      ...(pressed !== undefined ? { pressedMenuBarItem: pressed } : {}),
    });
    const stateText = [
      helperHeader.startsWith("App: ") ? helperHeader : "",
      screenshot ? screenshotCoordinateNote(screenshot) : "",
      condensed,
    ]
      .filter((part) => part !== "")
      .join("\n");

    // A diff is only correct when every index means the same element
    // as in the last text the model received. When the numbering
    // changed (a query read, or elements added or removed), unchanged
    // lines would silently carry new indices, so the full text is sent.
    let outputText = stateText;
    const previous = previousStateByApp.get(canonicalApp);
    const mappingKey = elementIds.mappingKey(canonicalApp);
    previousStateByApp.set(canonicalApp, { text: stateText, mappingKey });
    if (
      !resolved.disableDiff &&
      !resolved.query &&
      previous !== undefined &&
      previous.mappingKey === mappingKey
    ) {
      outputText = formatAccessibilityDiff(previous.text, stateText);
    }

    if (
      res.appSpecificInstructions &&
      res.appSpecificInstructions.trim().length > 0 &&
      !seenAppInstructions.has(canonicalApp)
    ) {
      seenAppInstructions.add(canonicalApp);
      outputText = `<app_specific_instructions>\n${res.appSpecificInstructions.trim()}\n</app_specific_instructions>\n${outputText}`;
    }

    const tree = res.windowState?.rawTree;
    let change: DriverAppState["change"];
    if (resolved.reportChange && before && tree) {
      let summary = describeChange(before.snapshot, snapshotOf(tree));
      // The agent sees the printed diff. Content that differs from the
      // state before the action but not from what the agent last read
      // shows nothing, so it is not reported as a change.
      if (summary === "content" && outputText === NO_CHANGES_TEXT) {
        summary = null;
      }
      const note = inactiveClickNote(before, summary, res.isActive, sparse);
      change = { summary, ...(note ? { note } : {}) };
    }

    // The app may have moved its focus to another window (a window
    // closed and it picked a user's window). The read stays on the
    // window it was, and says where the focus went.
    const focused = tree?.focused_window;
    const previousFocus = focusedWindowByApp.get(canonicalApp);
    focusedWindowByApp.set(canonicalApp, focused?.id);
    const focusedWindow =
      resolved.reportChange &&
      focused !== undefined &&
      focused.id !== tree?.window_id &&
      focused.id !== previousFocus
        ? `focused window is now ${describeWindow(focused)}`
        : undefined;

    return {
      app: canonicalApp,
      text: outputText,
      screenshot,
      sparse,
      ...(change ? { change } : {}),
      ...(focusedWindow ? { focusedWindow } : {}),
    };
  };

  return {
    target: "mac",
    elementIds,
    actionSettler,

    resetSessionState(): void {
      previousStateByApp.clear();
      seenAppInstructions.clear();
      sparseByApp.clear();
      readWindowByApp.clear();
      focusedWindowByApp.clear();
      pressedElementByApp.clear();
      baselineByApp.clear();
      stateBeforeActionByApp.clear();
      canonicalAppByRequest.clear();
      userActiveRefusalByApp.clear();
      elementIds.clear();
    },

    async listApps() {
      await actionSettler.wait();
      return runWithPolicy(
        "list_apps",
        {},
        { mutating: false, listing: true },
        (_input, { signal }) => helperPort.request("list_apps", { blockedBundleIds: deniedForLists() }, { signal }),
      );
    },

    async listWindows(params = {}) {
      await actionSettler.wait();
      return runWithPolicy(
        "list_windows",
        params,
        { mutating: false, listing: true },
        (resolved, { signal }) =>
          helperPort.request("list_windows", { ...resolved, blockedBundleIds: deniedForLists() }, { signal }),
      );
    },

    async getAppState(params): Promise<DriverAppState> {
      await actionSettler.wait();
      return runWithPolicy(
        "get_app_state",
        params,
        { mutating: false },
        async (resolved, { signal }) => {
          // The read after an action keeps the window the action used, and so
          // does a query read that names no window: it looks for an element
          // where the agent is working and does not move the target. Any
          // other read takes the window the agent named, or the app's own pick.
          const requestedWindow =
            resolved.reportChange || (resolved.query && resolved.windowId === undefined)
              ? targetWindow(resolved.app, resolved.windowId)
              : resolved.windowId;
          const readSeq = ++activitySeq;
          try {
            const state = await readAppState(resolved, requestedWindow, signal);
            // A read the agent asked for shows the app as it is now, so a
            // refusal before it no longer blocks the next action. The read
            // after an action never clears one.
            if (!resolved.reportChange) {
              clearUserActive(state.app, readSeq);
            }
            return state;
          } catch (error) {
            // Every read of the window the action used can find it closed:
            // the first one, a read again for a window that just opened, and
            // the read for the image of a sparse tree. A closing window can
            // still be listed with no elements for the first read and be gone
            // for the next one. The window the helper could not find is the
            // one the action used, also when the plugin did not know which
            // that was (the app was named another way in the last read): the
            // helper names it in the error.
            if (resolved.reportChange && error instanceof ComputerUseError && error.code === "window_gone") {
              const gone = requestedWindow ?? error.windowId;
              if (gone !== undefined) {
                return windowGoneState(resolved.app, gone);
              }
            }
            throw error;
          }
        },
      );
    },

    // The whole wait is one read-only policy call: one deny-list check, one
    // abort signal, one audit entry. It takes no control lock.
    waitFor(params, run) {
      return runWithPolicy(
        "wait_for",
        params,
        { mutating: false },
        (resolved, { signal }) => {
          let canonicalApp = resolved.app;
          // The wait watches the window the agent named, else the one it last
          // read, however the app moves its focus meanwhile.
          const watched = targetWindow(resolved.app, resolved.windowId);
          const probe: WaitProbe = {
            async readTree({ timeoutMs }) {
              const res = await requestAppState(resolved.app, false, signal, timeoutMs, false, watched);
              canonicalApp = rememberCanonicalApp(resolved.app, res.app);
              return res.windowState?.rawTree ?? null;
            },
            captureSignature({ windowId, region, timeoutMs }) {
              return requestSignature(resolved.app, { windowId: windowId ?? watched, region }, signal, timeoutMs);
            },
            takeBaseline() {
              const key = canonicalAppByRequest.get(resolved.app) ?? resolved.app;
              const entry = baselineByApp.get(key);
              baselineByApp.delete(key);
              return entry && now() - entry.atMs <= PRE_ACTION_BASELINE_MAX_AGE_MS ? entry.baseline : undefined;
            },
            // A wait only looks. It never writes the numbering the agent
            // reads: a rebuilt map would give an index the agent holds a new
            // element and a matching expected signature, and the next click
            // would pass the helper's check on the wrong element.
            indexElement(nativeId) {
              return elementIds.indexOf(canonicalApp, nativeId);
            },
          };
          return run(probe, signal);
        },
      );
    },

    async click(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "click",
        params,
        { mutating: true, reportsChange: true },
        (resolved, { signal }) =>
          helperPort.request(
            "click",
            {
              app: resolved.app,
              ...blocked(),
              ...pointerLabel,
              ...windowParam(resolved.app, resolved.windowId),
              ...(resolved.x !== undefined ? { x: resolved.x } : {}),
              ...(resolved.y !== undefined ? { y: resolved.y } : {}),
              ...pressed(resolved.app, optionalElement(resolved.app, resolved.elementIndex, resolved.windowId)),
              ...(resolved.button !== undefined ? { button: resolved.button } : {}),
              ...(resolved.clickCount !== undefined
                ? { clickCount: resolved.clickCount }
                : {}),
              ...(resolved.holdKeys !== undefined
                ? { holdKeys: resolved.holdKeys }
                : {}),
              ...(resolved.duration !== undefined
                ? { duration: resolved.duration }
                : {}),
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async drag(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "drag",
        params,
        { mutating: true, reportsChange: true },
        (resolved, { signal }) =>
          helperPort.request(
            "drag",
            {
              app: resolved.app,
              ...blocked(),
              ...pointerLabel,
              ...windowParam(resolved.app, resolved.windowId),
              fromX: resolved.fromX,
              fromY: resolved.fromY,
              toX: resolved.toX,
              toY: resolved.toY,
              ...(resolved.holdKeys !== undefined
                ? { holdKeys: resolved.holdKeys }
                : {}),
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async scroll(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "scroll",
        params,
        { mutating: true, reportsChange: true },
        (resolved, { signal }) =>
          helperPort.request(
            "scroll",
            {
              app: resolved.app,
              ...blocked(),
              ...pointerLabel,
              ...windowParam(resolved.app, resolved.windowId),
              ...(resolved.x !== undefined ? { x: resolved.x } : {}),
              ...(resolved.y !== undefined ? { y: resolved.y } : {}),
              ...optionalElement(resolved.app, resolved.elementIndex, resolved.windowId),
              direction: resolved.direction,
              pages: resolved.pages,
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async pressKey(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "press_key",
        params,
        { mutating: true, reportsChange: true, textLength: params.key.length },
        (resolved, { signal }) =>
          helperPort.request(
            "press_key",
            {
              app: resolved.app,
              ...blocked(),
              ...windowParam(resolved.app, resolved.windowId),
              key: resolved.key,
              ...(resolved.duration !== undefined
                ? { duration: resolved.duration }
                : {}),
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async typeText(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "type_text",
        params,
        { mutating: true, textLength: params.text.length },
        (resolved, { signal }) =>
          helperPort.request(
            "type_text",
            {
              app: resolved.app,
              ...blocked(),
              text: resolved.text,
              // The helper pastes instead of typing when an input method such
              // as Telex or VNI is active, and never switches the input source.
              allowInputMethod: false,
              ...windowParam(resolved.app, resolved.windowId),
              ...optionalElement(resolved.app, resolved.elementIndex, resolved.windowId),
            },
            { signal, timeoutMs: typeTextTimeoutMs(resolved.text), ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return withElementIndex(result, params.elementIndex);
    },

    async paste(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "paste_text",
        params,
        { mutating: true, textLength: params.text.length },
        (resolved, { signal }) =>
          helperPort.request(
            "paste_text",
            {
              app: resolved.app,
              ...blocked(),
              text: resolved.text,
              ...windowParam(resolved.app, resolved.windowId),
              ...optionalElement(resolved.app, resolved.elementIndex, resolved.windowId),
              ...(resolved.format !== undefined ? { format: resolved.format } : {}),
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return withElementIndex(result, params.elementIndex);
    },

    async setValue(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "set_value",
        params,
        { mutating: true, textLength: params.value.length },
        (resolved, { signal }) =>
          helperPort.request(
            "set_value",
            {
              app: resolved.app,
              ...blocked(),
              ...windowParam(resolved.app, resolved.windowId),
              ...resolveElement(resolved.app, resolved.elementIndex, resolved.windowId),
              value: resolved.value,
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async selectText(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "select_text",
        params,
        { mutating: true, textLength: params.text.length },
        (resolved, { signal }) =>
          helperPort.request(
            "select_text",
            {
              app: resolved.app,
              ...blocked(),
              ...windowParam(resolved.app, resolved.windowId),
              ...resolveElement(resolved.app, resolved.elementIndex, resolved.windowId),
              text: resolved.text,
              ...(resolved.prefix !== undefined ? { prefix: resolved.prefix } : {}),
              ...(resolved.suffix !== undefined ? { suffix: resolved.suffix } : {}),
              ...(resolved.selection !== undefined
                ? { selection: resolved.selection }
                : {}),
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },

    async performSecondaryAction(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "secondary_action",
        params,
        { mutating: true, reportsChange: true },
        (resolved, { signal }) =>
          helperPort.request(
            "perform_secondary_action",
            {
              app: resolved.app,
              ...blocked(),
              ...windowParam(resolved.app, resolved.windowId),
              ...pressed(resolved.app, resolveElement(resolved.app, resolved.elementIndex, resolved.windowId)),
              action: resolved.action,
            },
            { signal, ...actionMeta() },
          ),
      );
      actionSettler.defer();
      return result;
    },
  };
}
