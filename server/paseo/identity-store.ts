import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

export interface ClientIdentityRecord {
  clientId: string;
  agentId: string;
  provider?: string;
  updatedAt: string;
}

export class ClientIdentityStore {
  private readonly filePath: string;
  private readonly records = new Map<string, ClientIdentityRecord>();
  // Bindings seen at session open but not yet confirmed by agent.created.
  // They resolve at once (the agent's MCP server connects before the host
  // emits agent.created) but are not written to disk, so a create that fails
  // half way leaves nothing behind after a restart.
  private readonly unconfirmed = new Set<string>();

  constructor(stateDir: string) {
    this.filePath = path.join(stateDir, "client-bindings.json");
    this.load();
  }

  private load(): void {
    if (!existsSync(this.filePath)) return;
    try {
      const raw = JSON.parse(readFileSync(this.filePath, "utf8")) as Record<
        string,
        ClientIdentityRecord
      >;
      if (raw && typeof raw === "object") {
        for (const [clientId, rec] of Object.entries(raw)) {
          if (rec && typeof rec.agentId === "string" && rec.agentId.length > 0) {
            this.records.set(clientId, rec);
          }
        }
      }
    } catch {
      // Ignore corrupt state file
    }
  }

  private save(): void {
    try {
      const dir = path.dirname(this.filePath);
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const tmp = `${this.filePath}.tmp-${process.pid}-${Date.now()}`;
      const confirmed = [...this.records].filter(([clientId]) => !this.unconfirmed.has(clientId));
      const payload = JSON.stringify(Object.fromEntries(confirmed), null, 2);
      writeFileSync(tmp, payload, { encoding: "utf8", mode: 0o600 });
      chmodSync(tmp, 0o600);
      renameSync(tmp, this.filePath);
    } catch {
      // Best-effort persistence
    }
  }

  bind(clientId: string, agentId: string, provider?: string): void {
    if (!clientId || !agentId) return;
    this.records.set(clientId, {
      clientId,
      agentId,
      provider,
      updatedAt: new Date().toISOString(),
    });
    this.unconfirmed.add(clientId);
  }

  // Writes the agent's bindings to disk once the host confirms the agent
  // exists. Returns whether a binding for the agent was found.
  confirm(agentId: string): boolean {
    let found = false;
    for (const [clientId, rec] of this.records.entries()) {
      if (rec.agentId === agentId) {
        found = true;
        this.unconfirmed.delete(clientId);
      }
    }
    if (found) this.save();
    return found;
  }

  resolveAgentId(clientId: string): string | null {
    return this.records.get(clientId)?.agentId ?? null;
  }
}
