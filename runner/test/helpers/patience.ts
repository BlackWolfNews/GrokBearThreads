// How long a test waits for something that should happen.
//
// Agents' builds and tests run at background priority (taskpolicy -b, Mike's
// rule for the M5), which keeps them on the efficiency cores with every other
// thread's check. There a test's node child can take 20 s just to start, so
// limits of 3 to 20 s failed tests that were fine, a different handful each
// run, and `tb land` refused for no real reason (2 Nov).
//
// Every wait here ends the moment its condition holds, so a long limit costs
// nothing when a test passes, only time on one that's really broken. Waits
// that expect nothing to happen, like f.next(800), keep their short limits.
export const PATIENCE_MS = 60_000;

// Waits until cond holds or PATIENCE_MS is up. It doesn't throw: the assert
// after it says what went wrong better than "timed out" would.
export async function patiently(cond: () => boolean, pollMs = 20): Promise<void> {
  const end = Date.now() + PATIENCE_MS;
  while (!cond() && Date.now() < end) await new Promise((r) => setTimeout(r, pollMs));
}
