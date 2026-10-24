import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface, type Interface as ReadlineInterface } from "node:readline";
import {
  ComputerUseError,
  ComputerUseTransportError,
  PHYSICAL_ESCAPE_STOP_MESSAGE,
  USER_INTERVENED_STOP_MESSAGE,
} from "../contract/errors";
import type { HelperPort } from "../contract/helper-port";
import type {
  HelperCommandName,
  HelperCommands,
  HelperRequestEnvelope,
  HelperResponseEnvelope,
  HelperUnsolicitedEvent,
} from "../contract/helper-protocol";
import { buildHelperBinary, HELPER_SOURCE_HASH } from "./build";

export interface HelperProcessOptions {
  command?: string;
  args?: string[];
  env?: NodeJS.ProcessEnv;
  resolveBinary?: () => Promise<string>;
  defaultTimeoutMs?: number;
}

interface PendingRequest {
  id: number;
  cmd: HelperCommandName;
  params: unknown;
  resolve: (value: any) => void;
  reject: (reason: Error) => void;
  timer?: ReturnType<typeof setTimeout>;
  cleanupSignal?: () => void;
}

export class HelperProcess implements HelperPort {
  private readonly options: HelperProcessOptions;
  private child: ChildProcessWithoutNullStreams | null = null;
  private readline: ReadlineInterface | null = null;
  private spawnPromise: Promise<ChildProcessWithoutNullStreams> | null = null;
  private nextRequestId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly listeners = new Set<(event: HelperUnsolicitedEvent) => void>();
  private activeTurnId: string | null = null;
  private stopping = false;
  // Requests the plugin gave up on (timeout or abort), so a reply that still
  // arrives is logged instead of vanishing. Bounded: only recent ids matter.
  private readonly abandoned = new Map<number, HelperCommandName>();
  private static readonly maxAbandoned = 64;

  constructor(options: HelperProcessOptions = {}) {
    this.options = options;
  }

  onEvent(listener: (event: HelperUnsolicitedEvent) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  async request<K extends HelperCommandName>(
    cmd: K,
    params: HelperCommands[K]["params"],
    options?: { signal?: AbortSignal; timeoutMs?: number; meta?: Record<string, unknown> },
  ): Promise<HelperCommands[K]["result"]> {
    if (this.stopping) {
      throw new ComputerUseTransportError("HelperProcess is stopping.");
    }
    if (options?.signal?.aborted) {
      throw new ComputerUseError({
        code: "aborted_by_user",
        message: "Request was aborted before dispatch.",
        request: params,
        requestType: cmd,
      });
    }

    const incomingTurnId =
      typeof options?.meta?.turnId === "string" ? options.meta.turnId : null;
    if (
      incomingTurnId &&
      this.activeTurnId &&
      incomingTurnId !== this.activeTurnId &&
      cmd !== "end_turn" &&
      cmd !== "status"
    ) {
      this.activeTurnId = incomingTurnId;
      try {
        await this.sendRawRequest("end_turn", {} as Record<string, never>, {
          timeoutMs: 5_000,
        });
      } catch {
        // Ignore end_turn transition cleanup errors
      }
    } else if (incomingTurnId) {
      this.activeTurnId = incomingTurnId;
    }

    return this.sendRawRequest(cmd, params, options);
  }

  private async sendRawRequest<K extends HelperCommandName>(
    cmd: K,
    params: HelperCommands[K]["params"],
    options?: { signal?: AbortSignal; timeoutMs?: number; meta?: Record<string, unknown> },
  ): Promise<HelperCommands[K]["result"]> {
    const child = await this.ensureChild();
    const id = this.nextRequestId++;
    const timeoutMs = options?.timeoutMs ?? this.options.defaultTimeoutMs ?? 30_000;

    return new Promise<HelperCommands[K]["result"]>((resolve, reject) => {
      const entry: PendingRequest = {
        id,
        cmd,
        params,
        resolve,
        reject,
      };

      if (timeoutMs > 0) {
        entry.timer = setTimeout(() => {
          this.pending.delete(id);
          entry.cleanupSignal?.();
          // Without a cancel the helper would still run the command later,
          // out of the agent's view.
          this.abandon(id, cmd);
          reject(
            new ComputerUseTransportError(
              `Helper command '${cmd}' (id=${id}) timed out after ${timeoutMs}ms.`,
            ),
          );
        }, timeoutMs);
      }

      if (options?.signal) {
        const onAbort = () => {
          if (!this.pending.has(id)) return;
          this.pending.delete(id);
          if (entry.timer) clearTimeout(entry.timer);
          this.abandon(id, cmd);
          reject(
            new ComputerUseError({
              code: "aborted_by_user",
              message: "Request aborted by signal.",
              request: params,
              requestType: cmd,
            }),
          );
        };
        options.signal.addEventListener("abort", onAbort, { once: true });
        entry.cleanupSignal = () => options.signal?.removeEventListener("abort", onAbort);
      }

      this.pending.set(id, entry);

      const envelope: HelperRequestEnvelope<K> = {
        id,
        cmd,
        params,
        ...(options?.meta ? { meta: options.meta } : {}),
      };

      const line = `${JSON.stringify(envelope)}\n`;
      child.stdin.write(line, (err) => {
        if (err && this.pending.has(id)) {
          this.pending.delete(id);
          if (entry.timer) clearTimeout(entry.timer);
          entry.cleanupSignal?.();
          reject(
            new ComputerUseTransportError(`Failed to write command '${cmd}' to helper stdin.`, {
              cause: err,
            }),
          );
        }
      });
    });
  }

  // Records an abandoned request and asks the helper to stop it. The cancel
  // goes only to the running helper: starting a new one to cancel a command
  // the old one was running would be pointless.
  private abandon(id: number, cmd: HelperCommandName): void {
    this.abandoned.set(id, cmd);
    if (this.abandoned.size > HelperProcess.maxAbandoned) {
      const oldest = this.abandoned.keys().next().value;
      if (oldest !== undefined) this.abandoned.delete(oldest);
    }
    if (cmd === "cancel" || !this.isChildAlive()) {
      return;
    }
    this.sendRawRequest("cancel", { requestId: id }, { timeoutMs: 2_000 }).catch(() => {
      // The helper may exit before it answers; the request is already
      // rejected on the plugin side.
    });
  }

  private isChildAlive(): boolean {
    return this.child !== null && this.child.exitCode === null && !this.child.killed;
  }

  private async ensureChild(): Promise<ChildProcessWithoutNullStreams> {
    if (this.child && this.isChildAlive()) {
      return this.child;
    }
    if (this.spawnPromise) {
      return this.spawnPromise;
    }

    this.spawnPromise = (async () => {
      const command =
        this.options.command ??
        (this.options.resolveBinary
          ? await this.options.resolveBinary()
          : await buildHelperBinary());
      const args = this.options.args ?? [];

      const child = spawn(command, args, {
        stdio: ["pipe", "pipe", "pipe"],
        env: {
          ...process.env,
          PASEO_HELPER_SOURCE_HASH: HELPER_SOURCE_HASH,
          ...this.options.env,
        },
      });

      this.child = child;
      this.setupChildStreams(child);
      return child;
    })();

    try {
      return await this.spawnPromise;
    } finally {
      this.spawnPromise = null;
    }
  }

  private setupChildStreams(child: ChildProcessWithoutNullStreams): void {
    const rl = createInterface({ input: child.stdout });
    this.readline = rl;

    rl.on("line", (rawLine) => {
      const line = rawLine.trim();
      if (!line) return;

      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        this.emitEvent({
          event: "log",
          level: "warn",
          message: `Malformed NDJSON from helper: ${line.slice(0, 200)}`,
        });
        return;
      }

      if (!parsed || typeof parsed !== "object") return;
      const obj = parsed as Record<string, unknown>;

      if (typeof obj.event === "string") {
        this.handleUnsolicitedEvent(obj as unknown as HelperUnsolicitedEvent);
        return;
      }

      if (typeof obj.id === "number") {
        this.handleResponse(obj as unknown as HelperResponseEnvelope);
      }
    });

    child.stderr.on("data", (chunk: Buffer) => {
      const msg = chunk.toString("utf8").trim();
      if (msg) {
        this.emitEvent({
          event: "log",
          level: "warn",
          message: msg,
        });
      }
    });

    child.on("exit", (code, signal) => {
      this.readline?.close();
      this.readline = null;
      if (this.child === child) {
        this.child = null;
      }
      // Subscribers reset state the old process held, such as the armed
      // Escape tap. The next process starts unarmed.
      this.emitEvent({ event: "exited", code, signal });

      if (code === 130 || signal === "SIGINT") {
        const abortEvent: HelperUnsolicitedEvent = {
          event: "abort",
          reason: "escape_key",
          message: PHYSICAL_ESCAPE_STOP_MESSAGE,
        };
        this.emitEvent(abortEvent);
        this.rejectAllPending(
          (entry) =>
            new ComputerUseError({
              code: "aborted_by_user",
              message: PHYSICAL_ESCAPE_STOP_MESSAGE,
              request: entry.params,
              requestType: entry.cmd,
            }),
        );
        return;
      }

      if (!this.stopping) {
        this.rejectAllPending(
          () =>
            new ComputerUseTransportError(
              `Helper process exited unexpectedly (code=${code ?? "null"}, signal=${signal ?? "null"}).`,
            ),
        );
      } else {
        this.rejectAllPending(
          () => new ComputerUseTransportError("Helper process stopped."),
        );
      }
    });

    child.on("error", (err) => {
      this.rejectAllPending(
        () => new ComputerUseTransportError(`Helper process error: ${err.message}`, { cause: err }),
      );
    });
  }

  private handleUnsolicitedEvent(event: HelperUnsolicitedEvent): void {
    this.emitEvent(event);

    if (event.event === "abort") {
      const isEscape = event.reason === "escape_key";
      const code = isEscape
        ? "aborted_by_user"
        : "user_intervened";
      const fallbackMessage = isEscape
        ? PHYSICAL_ESCAPE_STOP_MESSAGE
        : USER_INTERVENED_STOP_MESSAGE;
      const message = event.message ?? fallbackMessage;

      this.rejectAllPending(
        (entry) =>
          new ComputerUseError({
            code,
            message,
            request: entry.params,
            requestType: entry.cmd,
          }),
      );
    }
  }

  private handleResponse(envelope: HelperResponseEnvelope): void {
    const entry = this.pending.get(envelope.id);
    if (!entry) {
      const abandonedCmd = this.abandoned.get(envelope.id);
      if (abandonedCmd !== undefined) {
        this.abandoned.delete(envelope.id);
        // The error reply of a command the plugin cancelled is expected.
        const cancelledReply =
          !envelope.ok && envelope.error?.code === "aborted_by_user";
        if (abandonedCmd !== "cancel" && !cancelledReply) {
          this.emitEvent({
            event: "log",
            level: "warn",
            message: `Late helper response for '${abandonedCmd}' (id=${envelope.id}) after the request timed out or was aborted; result ignored (ok=${envelope.ok}).`,
          });
        }
      }
      return;
    }
    this.pending.delete(envelope.id);
    if (entry.timer) clearTimeout(entry.timer);
    entry.cleanupSignal?.();

    if (envelope.ok) {
      entry.resolve(envelope.result);
    } else {
      const errCode = envelope.error?.code ?? "internal_error";
      const errMsg = envelope.error?.message ?? "Unknown helper error";
      entry.reject(
        new ComputerUseError({
          code: errCode,
          message: errMsg,
          request: entry.params,
          requestType: entry.cmd,
        }),
      );
    }
  }

  private emitEvent(event: HelperUnsolicitedEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch {
        // Ignore listener exceptions
      }
    }
  }

  private rejectAllPending(makeError: (entry: PendingRequest) => Error): void {
    for (const [id, entry] of this.pending.entries()) {
      this.pending.delete(id);
      if (entry.timer) clearTimeout(entry.timer);
      entry.cleanupSignal?.();
      entry.reject(makeError(entry));
    }
  }

  async stop(): Promise<void> {
    this.stopping = true;
    const child = this.child;
    if (!child || child.exitCode !== null) {
      this.child = null;
      this.stopping = false;
      return;
    }

    try {
      await this.sendRawRequest("end_turn", {} as Record<string, never>, {
        timeoutMs: 500,
      });
    } catch {
      // Ignore error on shutdown
    }

    await new Promise<void>((resolve) => {
      const killTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {}
        resolve();
      }, 1_000);

      child.once("exit", () => {
        clearTimeout(killTimer);
        resolve();
      });

      try {
        child.stdin.end();
        child.kill("SIGTERM");
      } catch {
        clearTimeout(killTimer);
        resolve();
      }
    });

    this.child = null;
    this.stopping = false;
  }
}
