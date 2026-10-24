export interface AuditEntry {
  timestamp: string;
  callerId: string;
  toolName: string;
  app: string | null;
  status: string;
  durationMs: number;
  textLength?: number;
}

export interface RecordAuditInput {
  timestamp?: string;
  callerId: string;
  toolName: string;
  app?: string | null;
  status: string;
  durationMs: number;
  textLength?: number;
}

export class AuditLog {
  private readonly maxEntries: number;
  private readonly entries: AuditEntry[] = [];

  constructor(maxEntries = 200) {
    this.maxEntries = Math.max(1, maxEntries);
  }

  record(input: RecordAuditInput): AuditEntry {
    const entry: AuditEntry = {
      timestamp: input.timestamp ?? new Date().toISOString(),
      callerId: input.callerId,
      toolName: input.toolName,
      app: input.app ?? null,
      status: input.status,
      durationMs: Math.max(0, Math.round(input.durationMs)),
      ...(input.textLength !== undefined ? { textLength: input.textLength } : {}),
    };

    if (this.entries.length >= this.maxEntries) {
      this.entries.shift();
    }
    this.entries.push(entry);
    return entry;
  }

  list(): AuditEntry[] {
    return this.entries.map((entry) => ({ ...entry }));
  }

  clear(): void {
    this.entries.length = 0;
  }
}
