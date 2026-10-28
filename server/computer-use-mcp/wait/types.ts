import type { RawAXTree } from "../contract/results";
import type { Region } from "./conditions";
import type { PreActionBaseline, SignatureCapture } from "./signature";

// What the poll loop needs from the driver. Every call runs inside the one
// policy check of the wait, so the deny list and the abort signal cover all
// polls and the audit log gets one entry per wait.
export interface WaitProbe {
  // The app's accessibility tree, or null when it has no readable content.
  // `timeoutMs` bounds the read, so a hung app cannot outlast the wait.
  readTree(params: { timeoutMs: number }): Promise<RawAXTree | null>;
  // The grayscale signature of the window image (or a region of it).
  captureSignature(params: { windowId?: number; region?: Region; timeoutMs: number }): Promise<SignatureCapture>;
  // The whole-window signature taken just before the app's last action, if
  // there is a recent one. Handing it out clears it, so one action is the
  // baseline of one wait.
  takeBaseline(): PreActionBaseline | undefined;
  // The index the agent already holds for this element, from the numbering of
  // its last read of the app. It never changes that numbering, so an index the
  // agent holds keeps naming the element it named. Undefined when the last
  // numbering has no such element.
  indexElement(nativeId: string): number | undefined;
}
