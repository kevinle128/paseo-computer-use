import { describe, expect, it } from "vitest";
import {
  CELL_DIFFERENCE_THRESHOLD,
  cropSignature,
  decodeSignature,
  SIGNATURE_BYTES,
  signaturesDiffer,
} from "../../server/computer-use-mcp/wait/signature";
import { captureOf, signatureOf } from "./fixtures";

describe("image signatures", () => {
  it("treats identical signatures as the same", () => {
    expect(signaturesDiffer(signatureOf(100), signatureOf(100))).toBe(false);
  });

  it("ignores a brightness shift of up to the cell threshold in every cell", () => {
    expect(signaturesDiffer(signatureOf(100), signatureOf(100 + CELL_DIFFERENCE_THRESHOLD))).toBe(false);
    expect(signaturesDiffer(signatureOf(100), signatureOf(100 + CELL_DIFFERENCE_THRESHOLD + 1))).toBe(true);
  });

  it("needs more than 1% of the cells to differ", () => {
    // 1% of 2560 cells is 25.6, so 25 different cells is not a change and 26 is.
    expect(signaturesDiffer(signatureOf(0), signatureOf(0, 25))).toBe(false);
    expect(signaturesDiffer(signatureOf(0), signatureOf(0, 26))).toBe(true);
  });

  it("decodes only a signature of the exact size", () => {
    const encoded = Buffer.from(signatureOf(9)).toString("base64");
    expect(decodeSignature(encoded)).toHaveLength(SIGNATURE_BYTES);
    expect(() => decodeSignature(Buffer.alloc(10).toString("base64"))).toThrow(/10-byte/);
  });

  it("crops a whole-window signature to the cells under a region", () => {
    // Window 800 x 400 points: one cell is 12.5 x 10 points.
    const bytes = signatureOf(0);
    bytes[0] = 200;
    bytes[1 * 64 + 1] = 100;
    const cropped = cropSignature(captureOf(bytes), { x: 0, y: 0, width: 25, height: 20 });
    expect(Array.from(cropped)).toEqual([200, 0, 0, 100]);
  });

  it("keeps one cell for a region smaller than a cell and clamps one past the edge", () => {
    expect(cropSignature(captureOf(signatureOf(9)), { x: 3, y: 3, width: 1, height: 1 })).toHaveLength(1);
    expect(cropSignature(captureOf(signatureOf(9)), { x: 790, y: 395, width: 100, height: 100 })).toHaveLength(1);
  });
});
