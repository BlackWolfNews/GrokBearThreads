// Times in words, both ways, for the threadbare tools and tb. Kept apart
// from threadbare-mcp.ts so tb doesn't load the Agent SDK to read "30m".

// "in 5m", "in 3h", "in 2d".
export function relativeFuture(iso: string, now: number): string {
  const s = Math.round((Date.parse(iso) - now) / 1000);
  if (s < 60) return 'now';
  if (s < 3600) return `in ${Math.round(s / 60)}m`;
  if (s < 86_400) return `in ${Math.round(s / 3600)}h`;
  return `in ${Math.round(s / 86_400)}d`;
}

export function relativeTime(iso: string, now: number): string {
  const s = Math.round((now - Date.parse(iso)) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86_400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86_400)}d ago`;
}

// "30m", "2h", "1d", "tomorrow" or an ISO time.
export function parseWhen(s: string, now: number): string {
  const m = /^\s*(\d+)\s*([mhd])\s*$/i.exec(s);
  if (m) {
    const ms = Number(m[1]) * { m: 60_000, h: 3_600_000, d: 86_400_000 }[m[2].toLowerCase() as 'm' | 'h' | 'd'];
    return new Date(now + ms).toISOString();
  }
  if (/^\s*tomorrow\s*$/i.test(s)) {
    const d = new Date(now);
    d.setDate(d.getDate() + 1);
    d.setHours(9, 0, 0, 0);
    return d.toISOString();
  }
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`Can't read the time "${s}". Use 30m, 2h, 1d, tomorrow or an ISO time.`);
  return new Date(t).toISOString();
}
