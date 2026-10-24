import net from "node:net";
import { ReadBuffer, serializeMessage } from "@modelcontextprotocol/sdk/shared/stdio.js";
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js";
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js";

// Speaks the plugin's socket protocol: one hello line, then newline-delimited
// JSON-RPC, exactly like the stdio shim that providers launch.
export class UnixSocketTransport implements Transport {
  onclose?: () => void;
  onerror?: (error: Error) => void;
  onmessage?: (message: JSONRPCMessage) => void;
  private socket: net.Socket | null = null;
  private readonly buffer = new ReadBuffer();

  constructor(
    private readonly socketPath: string,
    private readonly hello: { clientId: string; agentId?: string; provider?: string },
  ) {}

  async start(): Promise<void> {
    const socket = net.createConnection(this.socketPath);
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    socket.on("data", (chunk: Buffer) => {
      this.buffer.append(chunk);
      for (;;) {
        const message = this.buffer.readMessage();
        if (message === null) break;
        this.onmessage?.(message);
      }
    });
    socket.on("error", (error) => this.onerror?.(error));
    socket.on("close", () => this.onclose?.());
    socket.write(`${JSON.stringify({ hello: this.hello })}\n`);
    this.socket = socket;
  }

  async send(message: JSONRPCMessage): Promise<void> {
    this.socket?.write(serializeMessage(message));
  }

  async close(): Promise<void> {
    this.socket?.destroy();
    this.socket = null;
  }
}
