import { chmodSync, copyFileSync, existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

export const NODE_MCP_SHIM_SOURCE = String.raw`import net from "node:net";

const argv = process.argv.slice(2);
const getArg = (flag) => {
  const idx = argv.indexOf(flag);
  return idx >= 0 && idx + 1 < argv.length ? argv[idx + 1] : null;
};

const socketPath = getArg("--socket");
if (!socketPath) {
  process.stderr.write("paseo-computer-use-mcp: missing --socket <path>\n");
  process.exit(1);
}

const hello = {
  hello: {
    clientId: getArg("--client") ?? "",
    provider: getArg("--provider") ?? "",
    agentId: process.env.PASEO_AGENT_ID ?? null,
    agentCwd: process.env.PASEO_AGENT_CWD ?? null,
    pid: process.pid,
    ppid: process.ppid,
  },
};

const sock = net.createConnection(socketPath);
sock.on("connect", () => {
  sock.write(JSON.stringify(hello) + "\n");
  process.stdin.pipe(sock);
  sock.pipe(process.stdout);
});
sock.on("error", (err) => {
  process.stderr.write(
    "paseo-computer-use-mcp: cannot connect to " + socketPath + ": " + err.message + "\n",
  );
  process.exit(1);
});
sock.on("close", () => process.exit(0));
process.stdin.on("end", () => sock.end());
`;

/**
 * Quotes a value as one POSIX shell word. Inside single quotes the shell
 * expands nothing, so a path with spaces, `$`, backticks, or quotes reaches
 * the program unchanged. A single quote itself is closed, escaped, and
 * reopened.
 */
export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export interface InstallShimOptions {
  stateDir: string;
  socketPath?: string;
  compiledBinaryPath?: string;
  binaryName?: string;
}

export interface InstalledShimResult {
  shimPath: string;
  mode: "native" | "node-fallback";
}

export function getShimBinaryPath(
  stateDir: string,
  binaryName: string = "paseo-computer-use-mcp",
): string {
  return path.join(stateDir, "bin", binaryName);
}

export function installMcpShim(options: InstallShimOptions): InstalledShimResult {
  const binDir = path.join(options.stateDir, "bin");
  mkdirSync(binDir, { recursive: true, mode: 0o700 });

  const binaryName = options.binaryName ?? "paseo-computer-use-mcp";
  const shimPath = path.join(binDir, binaryName);
  const tmpPath = `${shimPath}.tmp.${process.pid}.${Date.now()}`;

  if (options.compiledBinaryPath && existsSync(options.compiledBinaryPath) && !options.socketPath) {
    copyFileSync(options.compiledBinaryPath, tmpPath);
    chmodSync(tmpPath, 0o755);
    renameSync(tmpPath, shimPath);
    return { shimPath, mode: "native" };
  }

  const shimMjsPath = path.join(binDir, "paseo-computer-use-shim.mjs");
  const tmpMjsPath = `${shimMjsPath}.tmp.${process.pid}.${Date.now()}`;
  writeFileSync(tmpMjsPath, NODE_MCP_SHIM_SOURCE, "utf8");
  renameSync(tmpMjsPath, shimMjsPath);

  const defaultSocketArg = options.socketPath ? ` --socket ${shellQuote(options.socketPath)}` : "";
  const nativeBin = options.compiledBinaryPath ? shellQuote(options.compiledBinaryPath) : null;
  const nativeBinCheck = nativeBin
    ? `if [ -x ${nativeBin} ]; then\n  exec ${nativeBin} --mcp-proxy${defaultSocketArg} "$@"\nfi\n`
    : "";

  const wrapperScript = `#!/bin/sh\n${nativeBinCheck}ELECTRON_RUN_AS_NODE=1 exec ${shellQuote(process.execPath)} ${shellQuote(shimMjsPath)}${defaultSocketArg} "$@"\n`;
  writeFileSync(tmpPath, wrapperScript, "utf8");
  chmodSync(tmpPath, 0o755);
  renameSync(tmpPath, shimPath);

  return {
    shimPath,
    mode:
      options.compiledBinaryPath && existsSync(options.compiledBinaryPath)
        ? "native"
        : "node-fallback",
  };
}
