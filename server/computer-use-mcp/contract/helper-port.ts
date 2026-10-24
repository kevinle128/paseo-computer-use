import type {
  HelperCommandName,
  HelperCommands,
  HelperUnsolicitedEvent,
} from "./helper-protocol";

export interface HelperPort {
  request<K extends HelperCommandName>(
    cmd: K,
    params: HelperCommands[K]["params"],
    options?: { signal?: AbortSignal; timeoutMs?: number; meta?: Record<string, unknown> },
  ): Promise<HelperCommands[K]["result"]>;

  onEvent(listener: (event: HelperUnsolicitedEvent) => void): () => void;

  stop(): Promise<void>;
}
