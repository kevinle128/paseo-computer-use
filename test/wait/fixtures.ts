import type { RawAXNode, RawAXTree } from "../../server/computer-use-mcp/contract/results";
import { SIGNATURE_BYTES, type SignatureCapture } from "../../server/computer-use-mcp/wait/signature";

export function node(path: string, role: string, extra: Partial<RawAXNode> = {}): RawAXNode {
  return { native_id: `7:${path}`, role, states: ["enabled"], ...extra };
}

export function treeOf(...windowChildren: RawAXNode[]): RawAXTree {
  return {
    window_id: 1,
    window_bounds: { x: 0, y: 0, width: 800, height: 600 },
    root: {
      native_id: "7:",
      role: "AXApplication",
      children: [
        node("0", "AXWindow", {
          name: "Untitled",
          bounds: { x: 0, y: 0, width: 800, height: 600 },
          actions: ["AXRaise"],
          children: windowChildren,
        }),
      ],
    },
  };
}

export function button(path: string, name: string, extra: Partial<RawAXNode> = {}): RawAXNode {
  return node(path, "AXButton", { name, actions: ["AXPress"], ...extra });
}

// A signature of one flat gray level; `changed` cells are set to another level.
export function signatureOf(level: number, changed = 0, changedLevel = 255): Uint8Array {
  const bytes = new Uint8Array(SIGNATURE_BYTES).fill(level);
  bytes.fill(changedLevel, 0, changed);
  return bytes;
}

// A whole-window capture of window 5, 800 x 400 points.
export function captureOf(bytes: Uint8Array, windowId = 5): SignatureCapture {
  return { bytes, windowId, windowWidth: 800, windowHeight: 400 };
}
