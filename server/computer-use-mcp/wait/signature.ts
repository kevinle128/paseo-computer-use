// Image signatures from the helper's `capture.signature` command: a small
// grayscale thumbnail. These constants mirror `CaptureSignature` in the Swift
// helper and are tuned in live QA.
export const SIGNATURE_WIDTH = 64;
export const SIGNATURE_HEIGHT = 40;
export const SIGNATURE_BYTES = SIGNATURE_WIDTH * SIGNATURE_HEIGHT;

// A cell counts as different when its brightness moved by more than this (of 255).
export const CELL_DIFFERENCE_THRESHOLD = 12;
// Two signatures differ when more than this share of cells are different.
export const CHANGED_CELL_FRACTION = 0.01;

// A signature taken before an action is a baseline for visual_changed only
// while it is this young.
export const PRE_ACTION_BASELINE_MAX_AGE_MS = 30_000;

// A signature and the window it shows (size in points).
export interface SignatureCapture {
  bytes: Uint8Array;
  windowId: number;
  windowWidth: number;
  windowHeight: number;
}

// The signature of the whole window taken before the last action.
export type PreActionBaseline = SignatureCapture;

// The cells of a whole-window signature that cover `region` (window points),
// row by row. At least one cell is kept, so a region at the edge still compares.
export function cropSignature(
  capture: SignatureCapture,
  region: { x: number; y: number; width: number; height: number },
): Uint8Array {
  const { windowWidth, windowHeight } = capture;
  if (windowWidth <= 0 || windowHeight <= 0 || capture.bytes.length !== SIGNATURE_BYTES) {
    return capture.bytes;
  }
  const cell = (point: number, size: number, cells: number, up: boolean) => {
    const scaled = (point / size) * cells;
    return Math.min(cells - 1, Math.max(0, up ? Math.ceil(scaled) - 1 : Math.floor(scaled)));
  };
  const firstCol = cell(region.x, windowWidth, SIGNATURE_WIDTH, false);
  const lastCol = Math.max(firstCol, cell(region.x + region.width, windowWidth, SIGNATURE_WIDTH, true));
  const firstRow = cell(region.y, windowHeight, SIGNATURE_HEIGHT, false);
  const lastRow = Math.max(firstRow, cell(region.y + region.height, windowHeight, SIGNATURE_HEIGHT, true));
  const out: number[] = [];
  for (let row = firstRow; row <= lastRow; row += 1) {
    for (let col = firstCol; col <= lastCol; col += 1) {
      out.push(capture.bytes[row * SIGNATURE_WIDTH + col]!);
    }
  }
  return Uint8Array.from(out);
}

export function decodeSignature(base64: string): Uint8Array {
  const bytes = new Uint8Array(Buffer.from(base64, "base64"));
  if (bytes.length !== SIGNATURE_BYTES) {
    throw new Error(
      `The helper returned a ${bytes.length}-byte image signature; expected ${SIGNATURE_BYTES}.`,
    );
  }
  return bytes;
}

export function signaturesDiffer(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return true;
  }
  let different = 0;
  for (let i = 0; i < a.length; i += 1) {
    if (Math.abs(a[i]! - b[i]!) > CELL_DIFFERENCE_THRESHOLD) {
      different += 1;
    }
  }
  return different > a.length * CHANGED_CELL_FRACTION;
}
