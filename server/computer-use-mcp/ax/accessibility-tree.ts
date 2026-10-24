import type { RawAXBounds, RawAXNode, RawAXTree } from "../contract/results";
import type { ElementIds, IndexedElement } from "./element-ids";

export interface CondenseAccessibilityTreeOptions {
  elementIds: ElementIds;
  // Canonical app identity (bundle id) that owns the numbered elements.
  app: string;
  query?: string;
}

interface TextAttribute {
  title?: string;
  text: string;
}

const CONTAINER_ROLES = new Set([
  "group",
  "panel",
  "filler",
  "section",
  "generic",
  "container",
]);

const TEXT_ROLES = new Set(["text", "static", "label", "statictext", "axstatictext"]);

const INTERACTIVE_ROLES = new Set([
  "push button",
  "button",
  "toggle button",
  "check box",
  "checkbox",
  "radio button",
  "entry",
  "text field",
  "textfield",
  "password text",
  "link",
  "menu item",
  "check menu item",
  "radio menu item",
  "combo box",
  "combobox",
  "pop up button",
  "popup button",
  "slider",
  "spin button",
  "scroll bar",
  "scroll pane",
  "viewport",
  "tab",
]);

const NON_INTERACTIVE_ONLY_ACTIONS = new Set([
  "dodefault",
  "clickancestor",
  "showcontextmenu",
  "scrolltovisible",
]);

const PRIMARY_DEFAULT_ACTIONS = new Set([
  "press",
  "axpress",
  "click",
  "dodefault",
  "clickancestor",
]);

const INTERACTIVE_STATES = new Set([
  "editable",
  "settable",
  "checkable",
  "focusable",
  "focused",
  "selected",
  "checked",
  "indeterminate",
  "expanded",
]);

export function normalizeRole(role: string): string {
  const normalized = role.trim().toLowerCase();
  if (CONTAINER_ROLES.has(normalized)) {
    return "container";
  }
  if (TEXT_ROLES.has(normalized)) {
    return "text";
  }
  if (normalized === "menu item") {
    return "";
  }
  return role.trim();
}

export function isContainerRole(role: string): boolean {
  return CONTAINER_ROLES.has(role.trim().toLowerCase());
}

export function isTextRole(role: string): boolean {
  return TEXT_ROLES.has(role.trim().toLowerCase());
}

function hasVisibleBounds(bounds?: RawAXBounds): boolean {
  if (!bounds) {
    return true;
  }
  return bounds.width > 0 && bounds.height > 0;
}

export function isInteractiveNode(node: RawAXNode): boolean {
  const statesLower = (node.states ?? []).map((s) => s.toLowerCase());
  if (statesLower.includes("hidden")) {
    return false;
  }
  if (!hasVisibleBounds(node.bounds)) {
    return false;
  }

  const actions = node.actions ?? [];
  const hasValidAction = actions.some(
    (action) => !NON_INTERACTIVE_ONLY_ACTIONS.has(action.trim().toLowerCase()),
  );
  if (hasValidAction) {
    return true;
  }

  if (statesLower.some((s) => INTERACTIVE_STATES.has(s))) {
    return true;
  }

  return INTERACTIVE_ROLES.has(node.role.trim().toLowerCase());
}

function hasInteractiveDescendant(node: RawAXNode): boolean {
  if (isInteractiveNode(node)) {
    return true;
  }
  return (node.children ?? []).some(hasInteractiveDescendant);
}

function extractNodeTexts(node: RawAXNode): TextAttribute[] {
  const attrs: TextAttribute[] = [];
  const seen = new Set<string>();
  const candidates: Array<[string | undefined, string | undefined]> = [
    [undefined, node.name],
    ["Description", node.description],
    ["Value", node.value],
  ];

  for (const [title, rawValue] of candidates) {
    if (rawValue === undefined || rawValue === null) {
      continue;
    }
    if (rawValue.trim() === "" || seen.has(rawValue)) {
      continue;
    }
    attrs.push({ title, text: rawValue });
    seen.add(rawValue);
  }
  return attrs;
}

function hasOwnMeaningfulContent(node: RawAXNode): boolean {
  if (extractNodeTexts(node).length > 0) {
    return true;
  }
  const roleLower = node.role.trim().toLowerCase();
  return roleLower === "image" || roleLower === "icon";
}

function hasMeaningfulStates(node: RawAXNode): boolean {
  const states = node.states ?? [];
  return states.some((s) =>
    [
      "focused",
      "selected",
      "expanded",
      "indeterminate",
      "checked",
      "checkable",
      "editable",
      "settable",
      "disabled",
    ].includes(s.toLowerCase()),
  );
}

function nodeMatchesQuery(node: RawAXNode, queryLower: string): boolean {
  const candidates = [
    node.role,
    normalizeRole(node.role),
    node.name,
    node.description,
    node.value,
    node.native_id,
  ];
  return candidates.some(
    (field) => typeof field === "string" && field.toLowerCase().includes(queryLower),
  );
}

function mergeBounds(nodes: RawAXNode[]): RawAXBounds | undefined {
  const boundsList = nodes.map((n) => n.bounds).filter((b): b is RawAXBounds => b !== undefined);
  if (boundsList.length === 0) {
    return undefined;
  }
  const minX = Math.min(...boundsList.map((b) => b.x));
  const minY = Math.min(...boundsList.map((b) => b.y));
  const maxX = Math.max(...boundsList.map((b) => b.x + b.width));
  const maxY = Math.max(...boundsList.map((b) => b.y + b.height));
  return {
    x: minX,
    y: minY,
    width: maxX - minX,
    height: maxY - minY,
  };
}

function pruneNode(
  node: RawAXNode,
  queryLower: string | undefined,
  ancestorMatched: boolean,
): RawAXNode | null {
  const statesLower = (node.states ?? []).map((s) => s.toLowerCase());
  if (statesLower.includes("hidden")) {
    return null;
  }

  const selfMatches =
    !queryLower || ancestorMatched || nodeMatchesQuery(node, queryLower);

  const prunedChildren: RawAXNode[] = [];
  for (const child of node.children ?? []) {
    const prunedChild = pruneNode(child, queryLower, selfMatches);
    if (prunedChild !== null) {
      prunedChildren.push(prunedChild);
    }
  }

  if (queryLower && !selfMatches && prunedChildren.length === 0) {
    return null;
  }

  const current: RawAXNode = {
    ...node,
    children: prunedChildren,
  };

  // Deduplicate leaf text children whose text is already a substring of the parent's name/description/value
  const parentTexts = extractNodeTexts(current).map((attr) => attr.text);
  if (parentTexts.length > 0 && !(current.children ?? []).some(hasInteractiveDescendant)) {
    let changed = true;
    while (changed) {
      changed = false;
      current.children = (current.children ?? []).flatMap((child) => {
        const childTexts = extractNodeTexts(child);
        if (
          isTextRole(child.role) &&
          !isInteractiveNode(child) &&
          childTexts.length > 0 &&
          childTexts.every((ct) => parentTexts.some((pt) => pt.includes(ct.text)))
        ) {
          changed = true;
          return child.children ?? [];
        }
        return [child];
      });
    }
  } else if (parentTexts.length > 0) {
    // Also deduplicate direct non-interactive leaf text children even when other siblings are interactive
    current.children = (current.children ?? []).filter((child) => {
      const childTexts = extractNodeTexts(child);
      const isLeafText =
        isTextRole(child.role) &&
        !isInteractiveNode(child) &&
        (child.children ?? []).length === 0;
      if (!isLeafText || childTexts.length === 0) {
        return true;
      }
      return !childTexts.every((ct) => parentTexts.some((pt) => pt.includes(ct.text)));
    });
  }

  const interactive = isInteractiveNode(current);

  // Merge adjacent non-interactive leaf text siblings with " "
  if (!interactive && (current.children ?? []).length > 1) {
    const mergedChildren: RawAXNode[] = [];
    let textRun: RawAXNode[] = [];

    const flushRun = () => {
      if (textRun.length === 0) {
        return;
      }
      if (textRun.length === 1) {
        mergedChildren.push(textRun[0]!);
      } else {
        const first = textRun[0]!;
        const combinedText = textRun
          .flatMap((item) => extractNodeTexts(item).map((attr) => attr.text))
          .join(" ");
        mergedChildren.push({
          ...first,
          role: "text",
          name: undefined,
          description: undefined,
          value: combinedText,
          bounds: mergeBounds(textRun),
          children: [],
        });
      }
      textRun = [];
    };

    for (const child of current.children ?? []) {
      const isLeafNonInteractiveText =
        isTextRole(child.role) &&
        !isInteractiveNode(child) &&
        (child.children ?? []).length === 0 &&
        extractNodeTexts(child).length > 0;

      if (isLeafNonInteractiveText) {
        textRun.push(child);
      } else {
        flushRun();
        mergedChildren.push(child);
      }
    }
    flushRun();
    current.children = mergedChildren;
  }

  const hasContent = hasOwnMeaningfulContent(current);
  const hasStates = hasMeaningfulStates(current);
  const children = current.children ?? [];

  // Drop empty non-interactive containers / nodes
  if (!interactive && !hasContent && !hasStates && children.length === 0) {
    return null;
  }

  // Collapse single-child non-interactive unlabelled containers
  if (!interactive && !hasContent && !hasStates && isContainerRole(current.role)) {
    const flattened = children.flatMap((child) => {
      if (
        isContainerRole(child.role) &&
        !isInteractiveNode(child) &&
        !hasOwnMeaningfulContent(child) &&
        !hasMeaningfulStates(child)
      ) {
        return child.children ?? [];
      }
      return [child];
    });
    current.children = flattened;
    if (flattened.length === 0) {
      return null;
    }
    if (flattened.length === 1) {
      return flattened[0]!;
    }
  }

  return current;
}

function isLongOrMultilineText(text: string): boolean {
  return text.length > 100 || text.includes("\n") || text.includes("\r");
}

function escapeSingleLine(text: string): string {
  return text.replaceAll("\r", "\\r").replaceAll("\n", "\\n").replaceAll("\t", "\\t");
}

function formatStates(node: RawAXNode): string {
  const rawStates = node.states ?? [];
  const statesLower = new Set(rawStates.map((s) => s.toLowerCase()));
  const formatted: string[] = [];

  for (const state of ["focused", "selected", "expanded", "indeterminate"]) {
    if (statesLower.has(state)) {
      formatted.push(state);
    }
  }

  if (statesLower.has("checked")) {
    formatted.push("checked");
  } else if (statesLower.has("checkable") && !statesLower.has("indeterminate")) {
    formatted.push("unchecked");
  }

  if (statesLower.has("editable") || statesLower.has("settable")) {
    formatted.push("settable");
  }

  if (statesLower.has("disabled")) {
    formatted.push("disabled");
  }

  return formatted.length > 0 ? `(${formatted.join(", ")})` : "";
}

function extractSecondaryActions(node: RawAXNode): string[] {
  const actions = node.actions ?? [];
  if (actions.length === 0) {
    return [];
  }
  const contextMenuCount = actions.filter(
    (a) => a.trim().toLowerCase() === "showcontextmenu",
  ).length;

  return actions.filter((action, index) => {
    const lower = action.trim().toLowerCase();
    if (index === 0 && PRIMARY_DEFAULT_ACTIONS.has(lower)) {
      return false;
    }
    if (contextMenuCount === 1 && lower === "showcontextmenu") {
      return false;
    }
    return true;
  });
}

function formatBounds(bounds?: RawAXBounds): string {
  if (!bounds || (bounds.width <= 0 && bounds.height <= 0)) {
    return "";
  }
  const x0 = Math.round(bounds.x);
  const x1 = Math.round(bounds.x + bounds.width);
  const y0 = Math.round(bounds.y);
  const y1 = Math.round(bounds.y + bounds.height);
  return `[${x0}..${x1}, ${y0}..${y1}]`;
}

function formatNodeLine(
  node: RawAXNode,
  depth: number,
  assignedIds: Map<string, number>,
): string {
  const indent = "  ".repeat(depth);
  const interactive = isInteractiveNode(node);
  const elementIndex = interactive ? assignedIds.get(node.native_id) : undefined;
  const indexPart = elementIndex !== undefined ? `[${elementIndex}]` : "";

  const displayRole = normalizeRole(node.role);
  const statesPart = formatStates(node);
  const boundsPart = formatBounds(node.bounds);

  const secondaryActions = extractSecondaryActions(node);
  const secondaryActionsPart =
    secondaryActions.length > 0 ? `Secondary Actions: (${secondaryActions.join(", ")})` : "";

  const textAttrs = extractNodeTexts(node);
  const shortAttrs = textAttrs.filter((attr) => !isLongOrMultilineText(attr.text));
  const longAttrs = textAttrs.filter((attr) => isLongOrMultilineText(attr.text));

  const formatAttr = (attr: TextAttribute): string => {
    const escaped = escapeSingleLine(attr.text);
    if (!attr.title || textAttrs.length === 1) {
      return escaped;
    }
    return `${attr.title}: ${escaped}`;
  };

  const shortTextPart = shortAttrs.map(formatAttr).join(", ");
  const longTextPart = longAttrs.map(formatAttr).join(", ");

  const parts = [
    indexPart,
    displayRole,
    statesPart,
    shortTextPart,
    secondaryActionsPart,
    boundsPart,
    longTextPart,
  ].filter((part) => part !== "");

  return `${indent}${parts.join(" ")}`;
}

export function condenseAccessibilityTree(
  tree: RawAXTree | null | undefined,
  options: CondenseAccessibilityTreeOptions,
): string {
  if (!tree) {
    return "";
  }

  const queryTrimmed = options.query?.trim();
  const queryLower = queryTrimmed ? queryTrimmed.toLowerCase() : undefined;

  const headerLines: string[] = [];
  if (tree.focused_element) {
    headerLines.push(`Focused Element: ${escapeSingleLine(tree.focused_element)}`);
  }
  if (tree.selected_text) {
    headerLines.push(`Selected Text: ${escapeSingleLine(tree.selected_text)}`);
  }
  if (tree.selected_elements && tree.selected_elements.length > 0) {
    headerLines.push(
      `Selected Elements: ${tree.selected_elements.map(escapeSingleLine).join(", ")}`,
    );
  }
  if (tree.document_text) {
    headerLines.push(`Document Text: ${escapeSingleLine(tree.document_text)}`);
  }

  const prunedRoot = tree.root ? pruneNode(tree.root, queryLower, false) : null;

  const interactiveElements: IndexedElement[] = [];
  const collectInteractiveIds = (node: RawAXNode | null) => {
    if (!node) {
      return;
    }
    if (isInteractiveNode(node) && node.native_id) {
      // Pruning copies interactive nodes unchanged, so these are the raw
      // values the helper recorded and will compare the live element with.
      interactiveElements.push({
        nativeId: node.native_id,
        expected: {
          role: node.role,
          ...(node.subrole ? { subrole: node.subrole } : {}),
          ...(node.name ? { name: node.name } : {}),
          ...(node.bounds ? { frame: node.bounds } : {}),
        },
      });
    }
    for (const child of node.children ?? []) {
      collectInteractiveIds(child);
    }
  };
  collectInteractiveIds(prunedRoot);

  const assignedIds = options.elementIds.assign(options.app, interactiveElements);

  const bodyLines: string[] = [];
  const walk = (node: RawAXNode | null, depth: number) => {
    if (!node) {
      return;
    }
    bodyLines.push(formatNodeLine(node, depth, assignedIds));
    for (const child of node.children ?? []) {
      walk(child, depth + 1);
    }
  };
  walk(prunedRoot, 0);

  if (headerLines.length > 0 && bodyLines.length > 0) {
    return `${headerLines.join("\n")}\n\n${bodyLines.join("\n")}`;
  }
  if (headerLines.length > 0) {
    return headerLines.join("\n");
  }
  return bodyLines.join("\n");
}

export function formatAccessibilityDiff(previousText: string, nextText: string): string {
  if (!previousText) {
    return nextText;
  }
  if (previousText === nextText) {
    return "No accessibility changes.";
  }

  const prevLines = previousText.split("\n");
  const nextLines = nextText.split("\n");

  const prevSet = new Set(prevLines);
  const nextSet = new Set(nextLines);

  const removed = prevLines.filter((line) => !nextSet.has(line));
  const added = nextLines.filter((line) => !prevSet.has(line));

  const totalLines = Math.max(prevLines.length, nextLines.length, 1);
  if (removed.length + added.length > totalLines * 1.2) {
    return nextText;
  }

  const diffLines: string[] = ["Accessibility diff:"];
  for (const line of removed) {
    diffLines.push(`- ${line}`);
  }
  for (const line of added) {
    diffLines.push(`+ ${line}`);
  }
  return diffLines.join("\n");
}
