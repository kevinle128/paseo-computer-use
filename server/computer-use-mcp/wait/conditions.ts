// The conditions wait_for can wait on, as one discriminated union. A new kind
// is a new member here plus a case in `createEvaluator`.

export const ELEMENT_STATES = ["enabled", "focused", "checked", "selected", "expanded"] as const;
export type ElementState = (typeof ELEMENT_STATES)[number];

// Window points, relative to the window's top-left corner.
export interface Region {
  x: number;
  y: number;
  width: number;
  height: number;
}

// At least one field is set; the schema enforces it.
export interface ElementSelector {
  role?: string;
  name?: string;
  nameContains?: string;
}

export type Condition =
  | { kind: "appears"; selector: ElementSelector }
  | { kind: "disappears"; selector: ElementSelector }
  | { kind: "state"; selector: ElementSelector; state: ElementState }
  | { kind: "value"; selector: ElementSelector; equals?: string; contains?: string }
  | { kind: "window"; titleContains?: string; titleNotContains?: string; present: boolean }
  | { kind: "stable"; quietMs: number }
  | { kind: "visual_stable"; quietMs: number; region?: Region }
  | { kind: "visual_changed"; region?: Region };

export interface NamedCondition {
  name: string;
  condition: Condition;
}

// Conditions that compare window images instead of reading the tree.
export function isVisualCondition(condition: Condition): boolean {
  return condition.kind === "visual_stable" || condition.kind === "visual_changed";
}

// Conditions whose names or titles are UI text, which follows the UI language.
export function matchesUiText(condition: Condition): boolean {
  switch (condition.kind) {
    case "appears":
    case "disappears":
    case "state":
    case "value":
      return condition.selector.name !== undefined || condition.selector.nameContains !== undefined;
    case "window":
      return condition.titleContains !== undefined || condition.titleNotContains !== undefined;
    default:
      return false;
  }
}
