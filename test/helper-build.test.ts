import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The shared in-flight build slot is used only for the default cache root,
// which build.ts computes from the home directory when the module loads.
// So this test points HOME at a temp dir and imports a fresh module.
describe("buildHelperBinary with a failing compiler", () => {
  let root: string;
  let previousHome: string | undefined;
  let previousPath: string | undefined;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), "paseo-cu-build-"));
    previousHome = process.env.HOME;
    previousPath = process.env.PATH;

    const binDir = path.join(root, "bin");
    mkdirSync(binDir);
    const fakeXcrun = path.join(binDir, "xcrun");
    writeFileSync(fakeXcrun, "#!/bin/sh\necho 'xcrun: error: compiler unavailable' >&2\nexit 1\n");
    chmodSync(fakeXcrun, 0o755);

    process.env.HOME = path.join(root, "home");
    process.env.PATH = `${binDir}${path.delimiter}${previousPath ?? ""}`;
    vi.resetModules();
  });

  afterEach(() => {
    process.env.HOME = previousHome;
    process.env.PATH = previousPath;
    rmSync(root, { recursive: true, force: true });
  });

  it("rejects to its caller without an unhandled rejection", async () => {
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => {
      unhandled.push(reason);
    };
    process.on("unhandledRejection", onUnhandled);
    try {
      const { buildHelperBinary, getCachedHelperBinaryPath } = await import(
        "../server/computer-use-mcp/helper/build"
      );
      expect(getCachedHelperBinaryPath().startsWith(path.join(root, "home"))).toBe(true);

      await expect(buildHelperBinary()).rejects.toThrow(/Failed to compile native helper binary/);
      // Let any side branch of the build promise settle before checking.
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));

      expect(unhandled).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });
});
