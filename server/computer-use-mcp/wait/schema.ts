import { z } from "zod";
import { ELEMENT_STATES, type NamedCondition, type Region } from "./conditions";

export const WAIT_MAX_CONDITIONS = 4;
export const WAIT_DEFAULT_TIMEOUT_MS = 5_000;
export const WAIT_MAX_TIMEOUT_MS = 30_000;
export const QUIET_MS_MIN = 100;
export const QUIET_MS_MAX = 5_000;

const text = z.string().trim().min(1);

const selectorShape = {
  role: text.optional().describe("Accessibility role, for example AXSheet. Not translated."),
  name: text.optional().describe("Element label, matched exactly and ignoring case."),
  name_contains: text.optional().describe("Text the label contains, ignoring case."),
};
const selectorMessage = "Give at least one of role, name, or name_contains.";
const hasSelector = (value: { role?: string; name?: string; name_contains?: string }) =>
  value.role !== undefined || value.name !== undefined || value.name_contains !== undefined;

const quietMs = z.number().int().min(QUIET_MS_MIN).max(QUIET_MS_MAX);
const region = z
  .object({
    x: z.number().finite().min(0),
    y: z.number().finite().min(0),
    width: z.number().finite().positive(),
    height: z.number().finite().positive(),
  })
  .strict()
  .describe("Area of the window in window points.");

const appears = z.object(selectorShape).strict().refine(hasSelector, { message: selectorMessage });
const disappears = z.object(selectorShape).strict().refine(hasSelector, { message: selectorMessage });
const state = z
  .object({ ...selectorShape, state: z.enum(ELEMENT_STATES) })
  .strict()
  .refine(hasSelector, { message: selectorMessage });
const value = z
  .object({
    ...selectorShape,
    value_equals: z.string().min(1).optional().describe("The element value equals this text (case-sensitive)."),
    value_contains: z.string().min(1).optional().describe("The element value contains this text (case-sensitive)."),
  })
  .strict()
  .refine(hasSelector, { message: selectorMessage })
  .refine((v) => (v.value_equals === undefined) !== (v.value_contains === undefined), {
    message: "Give exactly one of value_equals or value_contains.",
  });
const windowCondition = z
  .object({
    title_contains: text.optional(),
    title_not_contains: text.optional(),
    present: z.boolean().optional().describe("false waits until no window matches. Default true."),
  })
  .strict()
  .refine((v) => v.title_contains === undefined || v.title_not_contains === undefined, {
    message: "Give only one of title_contains or title_not_contains.",
  });
const stable = z.object({ quiet_ms: quietMs }).strict();
const visualStable = z.object({ quiet_ms: quietMs, region: region.optional() }).strict();
const visualChanged = z.object({ region: region.optional() }).strict();

const name = text.describe("Your label for this condition. The result names the one that was met.");

// One object per condition kind: `name` plus exactly one condition key.
export const waitConditionSchema = z.union([
  z.object({ name, appears }).strict(),
  z.object({ name, disappears }).strict(),
  z.object({ name, state }).strict(),
  z.object({ name, value }).strict(),
  z.object({ name, window: windowCondition }).strict(),
  z.object({ name, stable }).strict(),
  z.object({ name, visual_stable: visualStable }).strict(),
  z.object({ name, visual_changed: visualChanged }).strict(),
]);

type WaitConditionInput = z.output<typeof waitConditionSchema>;

function selectorOf(input: { role?: string; name?: string; name_contains?: string }) {
  return {
    ...(input.role !== undefined ? { role: input.role } : {}),
    ...(input.name !== undefined ? { name: input.name } : {}),
    ...(input.name_contains !== undefined ? { nameContains: input.name_contains } : {}),
  };
}

export function toNamedCondition(input: WaitConditionInput): NamedCondition {
  const label = input.name;
  if ("appears" in input) {
    return { name: label, condition: { kind: "appears", selector: selectorOf(input.appears) } };
  }
  if ("disappears" in input) {
    return { name: label, condition: { kind: "disappears", selector: selectorOf(input.disappears) } };
  }
  if ("state" in input) {
    return {
      name: label,
      condition: { kind: "state", selector: selectorOf(input.state), state: input.state.state },
    };
  }
  if ("value" in input) {
    const v = input.value;
    return {
      name: label,
      condition: {
        kind: "value",
        selector: selectorOf(v),
        ...(v.value_equals !== undefined ? { equals: v.value_equals } : {}),
        ...(v.value_contains !== undefined ? { contains: v.value_contains } : {}),
      },
    };
  }
  if ("window" in input) {
    const w = input.window;
    return {
      name: label,
      condition: {
        kind: "window",
        present: w.present ?? true,
        ...(w.title_contains !== undefined ? { titleContains: w.title_contains } : {}),
        ...(w.title_not_contains !== undefined ? { titleNotContains: w.title_not_contains } : {}),
      },
    };
  }
  if ("stable" in input) {
    return { name: label, condition: { kind: "stable", quietMs: input.stable.quiet_ms } };
  }
  if ("visual_stable" in input) {
    const v = input.visual_stable;
    return {
      name: label,
      condition: {
        kind: "visual_stable",
        quietMs: v.quiet_ms,
        ...(v.region ? { region: v.region as Region } : {}),
      },
    };
  }
  const changed = input.visual_changed;
  return {
    name: label,
    condition: { kind: "visual_changed", ...(changed.region ? { region: changed.region as Region } : {}) },
  };
}

export const waitForArgsShape = {
  window_id: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe("Window to watch, from list_windows or the Other windows line of get_app_state. Default: the window of your last get_app_state. Tree and visual conditions both watch it."),
  any: z
    .array(waitConditionSchema)
    .min(1)
    .max(WAIT_MAX_CONDITIONS)
    .describe("1 to 4 named conditions. The first one met ends the wait."),
  timeout_ms: z
    .number()
    .int()
    .min(1)
    .max(WAIT_MAX_TIMEOUT_MS)
    .optional()
    .describe(`Default ${WAIT_DEFAULT_TIMEOUT_MS}, at most ${WAIT_MAX_TIMEOUT_MS}.`),
};
