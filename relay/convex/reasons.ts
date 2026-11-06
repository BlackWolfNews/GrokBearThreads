// Plain TypeScript with no Convex imports, so the runner's unit tests can
// check it (runner/test/unit/push-health.test.ts).

// A failure's tally key: Apple's status and reason word, cut down so a
// strange body from Apple (or a socket error's text) can't grow the row.
// Never a device token: reasons are fixed words or error messages.
// Apple's reasons are single CamelCase words; the relay's own are a few
// fixed phrases; a socket error keeps only its code (ECONNREFUSED), as its
// message could carry anything. The rest is "other".
const OWN = new Set(['relay not configured', 'timeout', 'send threw']);
export function reasonKey(status: number, reason?: string): string {
  const r = (reason ?? '').trim();
  const word = !r ? '' : /^[A-Z][A-Za-z]{2,39}$/.test(r) || OWN.has(r) ? r : (r.match(/\bE[A-Z]{2,20}\b/)?.[0] ?? 'other');
  const code = Number.isFinite(status) ? Math.trunc(status) : 0;
  return word ? `${code} ${word}` : String(code);
}
// Different reasons kept per day; past that they all go under "other".
export const MAX_REASONS = 20;
