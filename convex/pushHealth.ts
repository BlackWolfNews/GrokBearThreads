// Whether this backend's pushes are getting through, so whoever runs it
// hears when they stop. On 5 and 6 Nov 2026 every push through the relay
// failed for two days (Apple had turned its key down) and nothing said so:
// each failure was a line in the deployment's logs, which nobody reads.
// Now push.ts records each send's outcome here, and the owner runner's
// heartbeat (sync.ts) carries what's failing to `tb status` and the app.
// Plain TypeScript with no Convex imports, so the runner's unit tests can
// check it.

export type PushVia = 'apple' | 'relay';

export type PushHealth = {
  lastOkAt?: number;
  // The first failure since the last push that got through, the latest,
  // how many, and the latest's "<status> <reason>".
  failingSince?: number;
  lastFailAt?: number;
  failed?: number;
  lastFailure?: string;
  via?: PushVia;
};

export type PushOutcome = { sent: number; failed: number; failure?: string; via: PushVia };

export type PushFailing = { failure: string; since: number; failed: number; via: PushVia };

// Failures older than this aren't news any more (no push has been tried
// since), so the warning goes rather than nagging for ever.
export const PUSH_FAILING_FRESH_MS = 3 * 86_400_000;

// A failure's text is a status and Apple's or the relay's reason, never a
// device token or thread text; cut in case a body is odd.
export const failureText = (status: number, reason?: string) => `${status}${reason ? ` ${reason.replace(/[^\w .:,'-]/g, '').slice(0, 120)}` : ''}`;

// One success clears it: some phone is getting them. A send with only
// failures starts or extends the failing run.
export function nextHealth(prev: PushHealth, o: PushOutcome, now: number): PushHealth {
  if (o.sent > 0) return { lastOkAt: now, via: o.via };
  if (o.failed <= 0) return prev;
  return {
    ...(prev.lastOkAt !== undefined ? { lastOkAt: prev.lastOkAt } : {}),
    failingSince: prev.failingSince ?? now,
    lastFailAt: now,
    failed: (prev.failed ?? 0) + o.failed,
    lastFailure: o.failure ?? prev.lastFailure ?? 'unknown',
    via: o.via,
  };
}

export function pushFailing(h: PushHealth | null, now: number): PushFailing | null {
  if (!h || h.failingSince === undefined || h.lastFailAt === undefined || now - h.lastFailAt > PUSH_FAILING_FRESH_MS) return null;
  return { failure: h.lastFailure ?? 'unknown', since: h.failingSince, failed: h.failed ?? 0, via: h.via ?? 'relay' };
}
