// Injectable clock so idle release and snooze timers can be tested with a
// fake clock instead of waiting 30 real minutes.
export type TimerHandle = { cancel(): void };

export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): TimerHandle;
}

export const realClock: Clock = {
  now: () => Date.now(),
  setTimeout(fn, ms) {
    const t = setTimeout(fn, Math.max(0, ms));
    // Timers must not keep a test process alive on their own.
    t.unref?.();
    return { cancel: () => clearTimeout(t) };
  },
};

export class FakeClock implements Clock {
  private t: number;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private nextId = 1;
  constructor(start = Date.parse('2026-10-26T12:00:00.000Z')) {
    this.t = start;
  }
  now(): number {
    return this.t;
  }
  setTimeout(fn: () => void, ms: number): TimerHandle {
    const id = this.nextId++;
    this.timers.push({ at: this.t + Math.max(0, ms), fn, id });
    return { cancel: () => (this.timers = this.timers.filter((x) => x.id !== id)) };
  }
  // Moves time forward, firing due timers in order.
  advance(ms: number): void {
    const end = this.t + ms;
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const next = this.timers[0];
      if (!next || next.at > end) break;
      this.timers.shift();
      this.t = next.at;
      next.fn();
    }
    this.t = end;
  }
  pending(): number {
    return this.timers.length;
  }
}
