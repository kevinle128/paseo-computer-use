// Why an action was refused before it did anything: the user was using the
// computer, or the agent had not read the app again since such a refusal.
export type AuditRefusal = "user_active" | "stale_state";

export interface AuditEntry {
  timestamp: string;
  callerId: string;
  toolName: string;
  app: string | null;
  status: string;
  durationMs: number;
  textLength?: number;
  userFocusChanged?: string;
  // The input idle times behind a focus watch outcome; see ActionExecutionResult.
  focusWatchDetail?: string;
  // Set with the status "refused".
  refusal?: AuditRefusal;
  // The rule and input idle times behind a `user_active` refusal. Kept here for live
  // tuning of the pause window; the agent never sees them.
  userActivityDetail?: string;
}

// What an action learns while it runs that its audit entry must keep.
export interface AuditDetail {
  userFocusChanged?: string;
  focusWatchDetail?: string;
  userActivityDetail?: string;
}

export interface RecordAuditInput {
  timestamp?: string;
  callerId: string;
  toolName: string;
  app?: string | null;
  status: string;
  durationMs: number;
  textLength?: number;
  userFocusChanged?: string;
  focusWatchDetail?: string;
  refusal?: AuditRefusal;
  userActivityDetail?: string;
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
      ...(input.userFocusChanged !== undefined ? { userFocusChanged: input.userFocusChanged } : {}),
      ...(input.focusWatchDetail !== undefined ? { focusWatchDetail: input.focusWatchDetail } : {}),
      ...(input.refusal !== undefined ? { refusal: input.refusal } : {}),
      ...(input.userActivityDetail !== undefined ? { userActivityDetail: input.userActivityDetail } : {}),
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
