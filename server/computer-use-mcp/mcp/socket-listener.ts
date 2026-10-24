import { chmodSync, existsSync, mkdirSync, statSync, unlinkSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import type { ComputerUseMcpServer } from "./server";

export interface SocketHelloPayload {
  clientId: string;
  provider?: string;
  agentId?: string | null;
  pid?: number;
}

export interface SocketListenerOptions {
  socketPath: string;
  createServerForClient: (hello: SocketHelloPayload) => ComputerUseMcpServer;
  // Called once when a connection that sent a hello closes.
  onClientClosed?: (hello: SocketHelloPayload) => void | Promise<void>;
}

export class ComputerUseSocketListener {
  private readonly socketPath: string;
  private readonly createServerForClient: (
    hello: SocketHelloPayload,
  ) => ComputerUseMcpServer;
  private readonly onClientClosed?: (hello: SocketHelloPayload) => void | Promise<void>;
  private server: net.Server | null = null;
  // Device and inode of the socket file this listener bound. stop() removes
  // the file only when it is still that one, so a listener that was refused,
  // or whose file another daemon has since replaced, never deletes a socket
  // that a live daemon serves.
  private ownedSocket: { dev: number; ino: number } | null = null;
  private readonly sockets = new Set<net.Socket>();

  constructor(options: SocketListenerOptions) {
    this.socketPath = options.socketPath;
    this.createServerForClient = options.createServerForClient;
    this.onClientClosed = options.onClientClosed;
  }

  getSocketPath(): string {
    return this.socketPath;
  }

  async start(): Promise<void> {
    if (this.server) {
      return;
    }

    mkdirSync(path.dirname(this.socketPath), { recursive: true });
    if (existsSync(this.socketPath)) {
      // A socket file left by a crashed daemon refuses connections and is
      // safe to remove. A socket that accepts one belongs to a running
      // daemon on the same Paseo home; removing it would cut that daemon's
      // agents off from their computer use tools.
      if (await isSocketLive(this.socketPath)) {
        throw new Error(
          `Another process is already serving computer use on ${this.socketPath}. ` +
            "Stop the other Paseo daemon that uses this Paseo home, then restart this one.",
        );
      }
      try {
        unlinkSync(this.socketPath);
      } catch {
        // listen() below reports the real problem if the file is still there.
      }
    }

    const netServer = net.createServer((socket) => {
      this.handleConnection(socket);
    });

    await new Promise<void>((resolve, reject) => {
      netServer.once("error", reject);
      netServer.listen(this.socketPath, () => {
        netServer.off("error", reject);
        resolve();
      });
    });

    try {
      chmodSync(this.socketPath, 0o600);
    } catch {
      // Ignore chmod errors on platforms that do not support socket permissions
    }

    this.server = netServer;
    try {
      const { dev, ino } = statSync(this.socketPath);
      this.ownedSocket = { dev, ino };
    } catch {
      this.ownedSocket = null;
    }
  }

  async stop(): Promise<void> {
    for (const socket of this.sockets) {
      socket.destroy();
    }
    this.sockets.clear();

    const current = this.server;
    this.server = null;
    if (current) {
      await new Promise<void>((resolve) => {
        current.close(() => resolve());
      });
    }

    const owned = this.ownedSocket;
    this.ownedSocket = null;
    if (owned) {
      try {
        const { dev, ino } = statSync(this.socketPath);
        if (dev === owned.dev && ino === owned.ino) {
          unlinkSync(this.socketPath);
        }
      } catch {
        // The file is already gone, or cleanup failed; nothing else to do.
      }
    }
  }

  private handleConnection(socket: net.Socket): void {
    this.sockets.add(socket);
    socket.setEncoding("utf8");

    let buffer = "";
    let mcpServer: ComputerUseMcpServer | null = null;
    let clientHello: SocketHelloPayload | null = null;
    let queue: Promise<void> = Promise.resolve();

    const processLine = async (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) {
        return;
      }

      let parsed: unknown;
      try {
        parsed = JSON.parse(trimmed);
      } catch {
        const errResp = {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32700, message: "Parse error" },
        };
        socket.write(`${JSON.stringify(errResp)}\n`);
        return;
      }

      if (
        mcpServer === null &&
        typeof parsed === "object" &&
        parsed !== null &&
        "hello" in parsed &&
        typeof (parsed as { hello?: unknown }).hello === "object" &&
        (parsed as { hello?: unknown }).hello !== null
      ) {
        const rawHello = (parsed as { hello: Record<string, unknown> }).hello;
        const hello: SocketHelloPayload = {
          clientId:
            typeof rawHello.clientId === "string" && rawHello.clientId.trim()
              ? rawHello.clientId.trim()
              : "anonymous",
          provider:
            typeof rawHello.provider === "string" ? rawHello.provider : undefined,
          agentId:
            typeof rawHello.agentId === "string" && rawHello.agentId.trim()
              ? rawHello.agentId.trim()
              : null,
          pid: typeof rawHello.pid === "number" ? rawHello.pid : undefined,
        };
        clientHello = hello;
        mcpServer = this.createServerForClient(hello);
        return;
      }

      if (mcpServer === null) {
        clientHello = { clientId: "default", agentId: null };
        mcpServer = this.createServerForClient(clientHello);
      }

      const response = await mcpServer.handleMessage(parsed);
      if (response !== null && !socket.destroyed) {
        socket.write(`${JSON.stringify(response)}\n`);
      }
    };

    socket.on("data", (chunk: string) => {
      buffer += chunk;
      for (;;) {
        const newlineIdx = buffer.indexOf("\n");
        if (newlineIdx === -1) {
          break;
        }
        const line = buffer.slice(0, newlineIdx);
        buffer = buffer.slice(newlineIdx + 1);
        queue = queue.then(() => processLine(line)).catch(() => {});
      }
    });

    socket.on("close", () => {
      this.sockets.delete(socket);
      const hello = clientHello;
      if (hello && this.onClientClosed) {
        void Promise.resolve(this.onClientClosed(hello)).catch(() => {
          // Releasing the lock is best effort; the idle timeout still applies.
        });
      }
    });

    socket.on("error", () => {
      this.sockets.delete(socket);
    });
  }
}

const LIVENESS_PROBE_TIMEOUT_MS = 1000;

/**
 * Resolves true when a process accepts a connection on the socket path. The
 * probe closes at once without a hello, so the other listener sees only an
 * empty connection.
 */
export function isSocketLive(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = net.createConnection(socketPath);
    const finish = (live: boolean) => {
      clearTimeout(timer);
      probe.removeAllListeners();
      probe.on("error", () => {});
      probe.destroy();
      resolve(live);
    };
    // A listener that never answers is not serving anyone either.
    const timer = setTimeout(() => finish(false), LIVENESS_PROBE_TIMEOUT_MS);
    probe.once("connect", () => finish(true));
    probe.once("error", () => finish(false));
  });
}
