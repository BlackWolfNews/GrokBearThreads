// The runner RPC's challenge auth (docs/protocol.md, "Auth"): neither side
// ever sends the token, each proves it has it with an HMAC over both sides'
// fresh nonces. Only node:crypto, so the .mjs tools (scripts/rpc-client.mjs,
// the mock and fake runners) can import it too.
import crypto from 'node:crypto';

export const AUTH_CONTEXT = 'threadbear-rpc-auth-v1';
export const AUTH_VERSION = 1;

export type AuthRole = 'client' | 'runner';

// 32 random bytes, lowercase hex.
export function newNonce(): string {
  return crypto.randomBytes(32).toString('hex');
}

export function isNonce(x: unknown): x is string {
  return typeof x === 'string' && /^[0-9a-f]{64}$/.test(x);
}

// The role is in what's signed so a runner's proof can't be played back as
// a client's (or the other way round) on a connection with the same nonces.
export function authProof(token: string, role: AuthRole, runnerNonce: string, clientNonce: string): string {
  return crypto.createHmac('sha256', Buffer.from(token, 'utf8')).update(`${AUTH_CONTEXT} ${role}\n${runnerNonce}\n${clientNonce}`).digest('hex');
}

export function proofMatches(expected: string, candidate: unknown): boolean {
  if (typeof candidate !== 'string') return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(candidate);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// A client's side of it. `challenge` is the runner's first message; it
// gives the auth.prove request to send and a check for the runner's answer.
// Anything that isn't a challenge throws: a client never falls back to
// sending the token.
export function answerChallenge(token: string, challenge: unknown, id: number | string = 1): {
  request: { jsonrpc: '2.0'; id: number | string; method: 'auth.prove'; params: { nonce: string; proof: string } };
  runnerProved: (result: unknown) => boolean;
} {
  const msg = challenge as { method?: unknown; params?: { nonce?: unknown } } | null;
  const runnerNonce = msg && typeof msg === 'object' ? msg.params?.nonce : undefined;
  if (msg?.method !== 'auth.challenge' || !isNonce(runnerNonce)) {
    throw new RunnerNotProvedError("The runner didn't send an auth challenge, so it isn't the runner or it's older than this client (it updates itself from main).");
  }
  const clientNonce = newNonce();
  return {
    request: { jsonrpc: '2.0', id, method: 'auth.prove', params: { nonce: clientNonce, proof: authProof(token, 'client', runnerNonce, clientNonce) } },
    runnerProved: (result) => proofMatches(authProof(token, 'runner', runnerNonce, clientNonce), (result as { proof?: unknown } | null)?.proof),
  };
}

export class RunnerNotProvedError extends Error {
  readonly notProved = true;
}
