// models/usage.ndjson: one line per model call that went out, so the
// Settings window can say what's been spent on OpenRouter and the daily
// budget can be kept across restarts. Never any text from the call.
import fs from 'node:fs';
import path from 'node:path';

export type UsageLine = {
  ts: string;
  feature: string;
  job: string;
  model: string;
  ok: boolean;
  ms: number;
  inputTokens?: number;
  outputTokens?: number;
  costUsd?: number;
  // A pool call: the login it ran on, and what the CLI says it would have
  // cost on the API. Not spent, so never added to the budget.
  accountId?: string;
  notionalUsd?: number;
  error?: string;
};

export function ledgerPath(home: string): string {
  return path.join(home, 'models', 'usage.ndjson');
}

// Keeps this month's costs in memory (read once at startup) and appends
// each new line to the file.
export class Ledger {
  private file: string;
  private costs: { at: number; usd: number }[] = [];

  constructor(home: string, now: number) {
    this.file = ledgerPath(home);
    const since = monthStart(now);
    let raw = '';
    try {
      raw = fs.readFileSync(this.file, 'utf8');
    } catch {
      return;
    }
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const u = JSON.parse(line) as UsageLine;
        const at = Date.parse(u.ts);
        if (at >= since && typeof u.costUsd === 'number' && u.costUsd > 0) this.costs.push({ at, usd: u.costUsd });
      } catch {
        // A line cut short by a crash; skip it.
      }
    }
  }

  add(u: UsageLine): void {
    if (typeof u.costUsd === 'number' && u.costUsd > 0) this.costs.push({ at: Date.parse(u.ts), usd: u.costUsd });
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.appendFileSync(this.file, JSON.stringify(u) + '\n');
    } catch {
      // The spend is still counted in memory; the file is a record.
    }
  }

  spentSince(since: number): number {
    let sum = 0;
    for (const c of this.costs) if (c.at >= since) sum += c.usd;
    return sum;
  }

  today(now: number): number {
    return this.spentSince(dayStart(now));
  }

  month(now: number): number {
    // Drop last month's lines while we're here.
    const since = monthStart(now);
    if (this.costs.length && this.costs[0].at < since) this.costs = this.costs.filter((c) => c.at >= since);
    return this.spentSince(since);
  }
}

// Local midnight and the 1st of the month, local time: "today" is Mike's day.
export function dayStart(now: number): number {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export function monthStart(now: number): number {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  d.setDate(1);
  return d.getTime();
}
