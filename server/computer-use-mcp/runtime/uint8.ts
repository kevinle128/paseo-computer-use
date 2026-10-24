import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export function fromDataUrl(url: string): { bytes: Uint8Array; mimeType: string } {
  if (!url.startsWith("data:")) {
    throw new TypeError("Expected a data: URL");
  }
  const commaIndex = url.indexOf(",");
  if (commaIndex === -1) {
    throw new TypeError("Malformed data: URL (missing comma)");
  }
  const header = url.slice(5, commaIndex);
  const payload = url.slice(commaIndex + 1);
  const parts = header.split(";").map((part) => part.trim()).filter(Boolean);
  const isBase64 = parts.includes("base64");
  const mimeParts = parts.filter((part) => part !== "base64");
  const mimeType = mimeParts[0] || "application/octet-stream";

  if (isBase64) {
    const buf = Buffer.from(payload, "base64");
    return {
      bytes: new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength),
      mimeType,
    };
  }

  const decoded = decodeURIComponent(payload);
  const buf = Buffer.from(decoded, "utf8");
  return {
    bytes: new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength),
    mimeType,
  };
}

export function toDataUrl(bytes: Uint8Array, mimeType: string): string {
  const base64 = Buffer.from(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength,
  ).toString("base64");
  return `data:${mimeType};base64,${base64}`;
}

export async function fromUrlOrFile(urlOrPath: string): Promise<Uint8Array> {
  if (urlOrPath.startsWith("data:")) {
    return fromDataUrl(urlOrPath).bytes;
  }
  const filePath = urlOrPath.startsWith("file://")
    ? fileURLToPath(urlOrPath)
    : urlOrPath;
  const buf = await readFile(filePath);
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}
