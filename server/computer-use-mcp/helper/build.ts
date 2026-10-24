import { execFile } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { HELPER_SOURCE_HASH, HELPER_SOURCES } from "./sources.generated";

export { HELPER_SOURCE_HASH, HELPER_SOURCES };

export interface BuildHelperOptions {
  cacheRootDir?: string;
  timeoutMs?: number;
  forceRebuild?: boolean;
}

const DEFAULT_CACHE_ROOT = path.join(homedir(), "Library", "Caches", "paseo-computer-use");

let inflightDefaultBuild: Promise<string> | null = null;

export function getCachedHelperBinaryPath(cacheRootDir: string = DEFAULT_CACHE_ROOT): string {
  return path.join(cacheRootDir, HELPER_SOURCE_HASH, "paseo-computer-use-helper");
}

export async function buildHelperBinary(options: BuildHelperOptions = {}): Promise<string> {
  const cacheRootDir = options.cacheRootDir ?? DEFAULT_CACHE_ROOT;
  const timeoutMs = options.timeoutMs ?? 300_000;
  const forceRebuild = options.forceRebuild ?? false;
  const targetBinPath = getCachedHelperBinaryPath(cacheRootDir);

  if (!forceRebuild && existsSync(targetBinPath)) {
    return targetBinPath;
  }

  const isDefault = cacheRootDir === DEFAULT_CACHE_ROOT && !forceRebuild;
  if (isDefault && inflightDefaultBuild) {
    return inflightDefaultBuild;
  }

  const buildPromise = (async () => {
    const hashDir = path.dirname(targetBinPath);
    const srcDir = path.join(hashDir, "src");
    mkdirSync(srcDir, { recursive: true });

    const swiftFiles: string[] = [];
    for (const [filename, content] of Object.entries(HELPER_SOURCES)) {
      const filePath = path.join(srcDir, filename);
      writeFileSync(filePath, content, "utf8");
      swiftFiles.push(filePath);
    }

    const tmpBinPath = `${targetBinPath}.tmp.${process.pid}.${Date.now()}`;
    const args = [
      "swiftc",
      "-O",
      "-swift-version",
      "5",
      "-o",
      tmpBinPath,
      ...swiftFiles,
    ];

    await new Promise<void>((resolve, reject) => {
      execFile("xcrun", args, { timeout: timeoutMs }, (err, _stdout, stderr) => {
        if (err) {
          try {
            if (existsSync(tmpBinPath)) unlinkSync(tmpBinPath);
          } catch {}
          reject(
            new Error(`Failed to compile native helper binary: ${err.message}\n${stderr}`),
          );
          return;
        }
        resolve();
      });
    });

    chmodSync(tmpBinPath, 0o755);
    renameSync(tmpBinPath, targetBinPath);
    return targetBinPath;
  })();

  if (isDefault) {
    inflightDefaultBuild = buildPromise;
    // Clear the shared slot on success or failure. The rejection itself is
    // handled by the caller of the returned promise; this side branch must
    // not create a second, unhandled rejection that would crash the process.
    const clearInflight = () => {
      if (inflightDefaultBuild === buildPromise) {
        inflightDefaultBuild = null;
      }
    };
    buildPromise.then(clearInflight, clearInflight);
  }

  return buildPromise;
}
