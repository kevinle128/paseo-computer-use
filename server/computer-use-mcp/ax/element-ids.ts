import type { ElementExpectation } from "../contract/results";

export interface IndexedElement {
  nativeId: string;
  // What the element looked like in the text the model read. The helper acts
  // only when the live element still looks like this, so another agent's read
  // of the same app can never change which element an index names.
  expected: ElementExpectation;
}

// Maps the element indices shown to the model to the helper's native ids.
// Indices are scoped to one app (keyed by its bundle id) and to the latest
// snapshot of that app: every snapshot replaces the whole mapping, so an index
// can only ever name an element from the text the model last saw for that app.
export class ElementIds {
  private readonly byApp = new Map<string, Map<number, IndexedElement>>();

  assign(app: string, elements: Iterable<IndexedElement>): Map<string, number> {
    const indexToElement = new Map<number, IndexedElement>();
    const nativeToIndex = new Map<string, number>();
    for (const element of elements) {
      const nativeId = element.nativeId.trim();
      if (!nativeId || nativeToIndex.has(nativeId)) {
        continue;
      }
      const index = indexToElement.size;
      indexToElement.set(index, { nativeId, expected: element.expected });
      nativeToIndex.set(nativeId, index);
    }
    this.byApp.set(app, indexToElement);
    return nativeToIndex;
  }

  resolve(app: string, elementIndex: number): IndexedElement | undefined {
    return this.byApp.get(app)?.get(elementIndex);
  }

  // The native ids in index order. Two reads with the same key give every
  // index the same native id, so a diff between them cannot hide a renumbering.
  mappingKey(app: string): string {
    return [...(this.byApp.get(app)?.values() ?? [])].map((element) => element.nativeId).join("\n");
  }

  clear(): void {
    this.byApp.clear();
  }
}
