// Plain TypeScript with no Convex imports, so the runner's unit tests can
// check it (runner/test/unit/push-health.test.ts).

// A failure's tally key: Apple's status and reason word, cut down so a
// strange body from Apple (or a socket error's text) can't grow the row.
// Never a device token: reasons are fixed words or error messages.
export function reasonKey(status: number, reason?: string): string {
  const word = (reason ?? '').replace(/[^\w .:-]/g, '').trim().slice(0, 40);
  return word ? `${status} ${word}` : String(status);
}
// Different reasons kept per day; past that they all go under "other".
export const MAX_REASONS = 20;
