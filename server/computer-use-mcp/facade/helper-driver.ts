import {
  condenseAccessibilityTree,
  formatAccessibilityDiff,
} from "../ax/accessibility-tree";
import { ElementIds, type IndexedElement } from "../ax/element-ids";
import { ComputerUseToolError } from "../contract/errors";
import type { HelperPort } from "../contract/helper-port";
import type { WindowScreenshot } from "../contract/results";
import { blockedBundleIds, type PolicyEngineConfig, withComputerUsePolicy } from "../policy";
import { ActionSettler } from "../runtime/action-settler";
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

export interface CreateHelperDriverOptions {
  helperPort: HelperPort;
  policy?: PolicyEngineConfig;
  elementIds?: ElementIds;
  actionSettler?: ActionSettler;
  // The agent name the helper shows next to the virtual pointer.
  overlayLabel?: string;
  getCallerContext?: () => {
    callerId: string;
    agentId?: string | null;
  };
}

export function createHelperDriver(options: CreateHelperDriverOptions): ComputerDriver & {
  resetSessionState(): void;
  readonly elementIds: ElementIds;
  readonly actionSettler: ActionSettler;
} {
  const { helperPort, policy } = options;
  const elementIds = options.elementIds ?? new ElementIds();
  const actionSettler = options.actionSettler ?? new ActionSettler(100);
  // The last text the model received for each app (from a full or a query
  // read) and the index numbering that text used.
  const previousStateByApp = new Map<string, { text: string; mappingKey: string }>();
  const seenAppInstructions = new Set<string>();
  // The app string an agent passes ("TextEdit", "com.apple.TextEdit") mapped
  // to the bundle id the helper resolved it to on the last get_app_state.
  // Element indices are looked up by that bundle id only.
  const canonicalAppByRequest = new Map<string, string>();

  // Turns a model-facing index into the helper's native id and the element as
  // this agent saw it, or refuses with stale_element. There is no fallback to
  // another app or an older snapshot.
  const resolveElement = (app: string, elementIndex: number): IndexedElement => {
    const canonicalApp = canonicalAppByRequest.get(app);
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
  // to the next command.
  const blocked = (): string[] => blockedBundleIds(policy?.getExtraBlockedBundleIds?.());

  const pointerLabel = options.overlayLabel ? { overlayLabel: options.overlayLabel } : {};

  const optionalElement = (app: string, elementIndex: number | undefined) =>
    elementIndex === undefined ? {} : resolveElement(app, elementIndex);

  const getContext = () =>
    options.getCallerContext?.() ?? {
      callerId: "default",
      agentId: null,
    };

  const runWithPolicy = async <TInput extends { app?: string }, TResult>(
    toolName: string,
    input: TInput,
    extra: { mutating: boolean; textLength?: number },
    fn: (resolvedInput: TInput, opts: { signal?: AbortSignal }) => Promise<TResult>,
  ): Promise<TResult> => {
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
        textLength: extra.textLength,
      },
      input,
      (resolved, { signal }) => fn(resolved, { signal }),
    );
  };

  return {
    target: "mac",
    elementIds,
    actionSettler,

    resetSessionState(): void {
      previousStateByApp.clear();
      seenAppInstructions.clear();
      canonicalAppByRequest.clear();
      elementIds.clear();
    },

    async listApps() {
      await actionSettler.wait();
      return runWithPolicy(
        "list_apps",
        {},
        { mutating: false },
        (_input, { signal }) => helperPort.request("list_apps", { blockedBundleIds: blocked() }, { signal }),
      );
    },

    async listWindows(params = {}) {
      await actionSettler.wait();
      return runWithPolicy(
        "list_windows",
        params,
        { mutating: false },
        (resolved, { signal }) =>
          helperPort.request("list_windows", { ...resolved, blockedBundleIds: blocked() }, { signal }),
      );
    },

    async getAppState(params): Promise<DriverAppState> {
      await actionSettler.wait();
      return runWithPolicy(
        "get_app_state",
        params,
        { mutating: false },
        async (resolved, { signal }) => {
          const res = await helperPort.request(
            "get_app_state",
            // The helper always returns the whole raw tree: query filtering
            // and diffing happen below on the plugin's own numbered text.
            {
              app: resolved.app,
              includeScreenshot: resolved.includeScreenshot,
              blockedBundleIds: blocked(),
            },
            { signal },
          );

          const canonicalApp =
            typeof res.app === "string"
              ? res.app
              : res.app.bundleIdentifier || res.app.displayName || resolved.app;
          canonicalAppByRequest.set(resolved.app, canonicalApp);
          canonicalAppByRequest.set(canonicalApp, canonicalApp);

          // Only the helper's header line is kept. Element lines always come
          // from the condensed tree, whose indices are the ones the plugin
          // can resolve; any numbered text from the helper is ignored.
          const helperHeader = (res.windowState?.text ?? "").split("\n", 1)[0] ?? "";
          const condensed = condenseAccessibilityTree(res.windowState?.rawTree, {
            elementIds,
            query: resolved.query,
            app: canonicalApp,
          });
          const screenshot = res.windowState?.screenshot ?? null;
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

          return {
            app: canonicalApp,
            text: outputText,
            screenshot,
          };
        },
      );
    },

    async click(params) {
      await actionSettler.wait();
      const result = await runWithPolicy(
        "click",
        params,
        { mutating: true },
        (resolved, { signal }) =>
          helperPort.request(
            "click",
            {
              app: resolved.app,
              blockedBundleIds: blocked(),
              ...pointerLabel,
              ...(resolved.x !== undefined ? { x: resolved.x } : {}),
              ...(resolved.y !== undefined ? { y: resolved.y } : {}),
              ...optionalElement(resolved.app, resolved.elementIndex),
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
            { signal },
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
        { mutating: true },
        (resolved, { signal }) =>
          helperPort.request(
            "drag",
            {
              app: resolved.app,
              blockedBundleIds: blocked(),
              ...pointerLabel,
              fromX: resolved.fromX,
              fromY: resolved.fromY,
              toX: resolved.toX,
              toY: resolved.toY,
              ...(resolved.holdKeys !== undefined
                ? { holdKeys: resolved.holdKeys }
                : {}),
            },
            { signal },
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
        { mutating: true },
        (resolved, { signal }) =>
          helperPort.request(
            "scroll",
            {
              app: resolved.app,
              blockedBundleIds: blocked(),
              ...pointerLabel,
              ...(resolved.x !== undefined ? { x: resolved.x } : {}),
              ...(resolved.y !== undefined ? { y: resolved.y } : {}),
              ...optionalElement(resolved.app, resolved.elementIndex),
              direction: resolved.direction,
              pages: resolved.pages,
            },
            { signal },
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
        { mutating: true, textLength: params.key.length },
        (resolved, { signal }) =>
          helperPort.request(
            "press_key",
            {
              app: resolved.app,
              blockedBundleIds: blocked(),
              key: resolved.key,
              ...(resolved.duration !== undefined
                ? { duration: resolved.duration }
                : {}),
            },
            { signal },
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
              blockedBundleIds: blocked(),
              text: resolved.text,
              // The helper pastes instead of typing when an input method such
              // as Telex or VNI is active, and never switches the input source.
              allowInputMethod: false,
              ...optionalElement(resolved.app, resolved.elementIndex),
            },
            { signal, timeoutMs: typeTextTimeoutMs(resolved.text) },
          ),
      );
      actionSettler.defer();
      return result;
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
              blockedBundleIds: blocked(),
              text: resolved.text,
              ...(resolved.format !== undefined ? { format: resolved.format } : {}),
            },
            { signal },
          ),
      );
      actionSettler.defer();
      return result;
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
              blockedBundleIds: blocked(),
              ...resolveElement(resolved.app, resolved.elementIndex),
              value: resolved.value,
            },
            { signal },
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
              blockedBundleIds: blocked(),
              ...resolveElement(resolved.app, resolved.elementIndex),
              text: resolved.text,
              ...(resolved.prefix !== undefined ? { prefix: resolved.prefix } : {}),
              ...(resolved.suffix !== undefined ? { suffix: resolved.suffix } : {}),
              ...(resolved.selection !== undefined
                ? { selection: resolved.selection }
                : {}),
            },
            { signal },
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
        { mutating: true },
        (resolved, { signal }) =>
          helperPort.request(
            "perform_secondary_action",
            {
              app: resolved.app,
              blockedBundleIds: blocked(),
              ...resolveElement(resolved.app, resolved.elementIndex),
              action: resolved.action,
            },
            { signal },
          ),
      );
      actionSettler.defer();
      return result;
    },
  };
}
