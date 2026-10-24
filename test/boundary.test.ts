import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

function collectSourceFiles(dir: string): string[] {
  if (!existsSync(dir)) {
    return [];
  }
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      results.push(...collectSourceFiles(full));
    } else if (full.endsWith(".ts") || full.endsWith(".tsx")) {
      results.push(full);
    }
  }
  return results;
}

describe("Architecture boundary checks", () => {
  it("never imports @getpaseo/* inside server/computer-use-mcp/**", () => {
    const mcpDir = path.join(repoRoot, "server", "computer-use-mcp");
    const files = collectSourceFiles(mcpDir);
    expect(files.length).toBeGreaterThan(0);

    for (const file of files) {
      const content = readFileSync(file, "utf8");
      const rel = path.relative(repoRoot, file);
      expect(content, `${rel} must not import @getpaseo/*`).not.toMatch(
        /from\s+["']@getpaseo\/|import\s*\(\s*["']@getpaseo\//,
      );
    }
  });

  it("never imports server/** inside client/**", () => {
    const clientDir = path.join(repoRoot, "client");
    const files = collectSourceFiles(clientDir);

    for (const file of files) {
      const content = readFileSync(file, "utf8");
      const rel = path.relative(repoRoot, file);
      expect(content, `${rel} must not import server/**`).not.toMatch(
        /from\s+["'](?:\.\.\/)+server\/|import\s*\(\s*["'](?:\.\.\/)+server\//,
      );
    }
  });
});
