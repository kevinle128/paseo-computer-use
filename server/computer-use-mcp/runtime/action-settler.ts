import { setTimeout as sleep } from "node:timers/promises";

export interface ActionSettlerClock {
  now(): number;
  sleep(ms: number): Promise<void>;
}

export interface ActionSettlerOptions {
  postActionSleepMs?: number;
  post_action_sleep_ms?: number;
}

const defaultClock: ActionSettlerClock = {
  now: () => performance.now(),
  sleep: async (ms: number) => {
    await sleep(ms);
  },
};

export class ActionSettler {
  private readonly delayMs: number;
  private readonly clock: ActionSettlerClock;
  private readyAtMs = 0;

  constructor(
    options: number | ActionSettlerOptions = 100,
    clock: ActionSettlerClock = defaultClock,
  ) {
    if (typeof options === "number") {
      this.delayMs = Math.max(0, options);
    } else {
      const configured =
        options.postActionSleepMs ?? options.post_action_sleep_ms ?? 100;
      this.delayMs = Math.max(0, configured);
    }
    this.clock = clock;
  }

  defer(): void {
    if (this.delayMs > 0) {
      this.readyAtMs = Math.max(this.readyAtMs, this.clock.now() + this.delayMs);
    }
  }

  async wait(): Promise<void> {
    for (;;) {
      const remaining = this.readyAtMs - this.clock.now();
      if (remaining <= 0) {
        return;
      }
      await this.clock.sleep(remaining);
    }
  }
}
