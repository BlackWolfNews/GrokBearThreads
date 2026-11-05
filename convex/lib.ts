// Shared by the runner-facing and phone-facing functions: who may call what.
import { ConvexError } from 'convex/values';
import type { QueryCtx, MutationCtx } from './_generated/server';
import type { Id } from './_generated/dataModel';

// The runner's mutations carry the key from its secrets/convex-key, which
// must match the deployment's RUNNER_KEY. Set with
// `npx convex env set RUNNER_KEY <key>` (and --prod).
export function checkRunnerKey(key: string): void {
  const want = process.env.RUNNER_KEY;
  if (!want || key !== want) throw new ConvexError({ kind: 'auth', message: 'bad runner key' });
}

// A phone's token (tokens.ts) is checked by its SHA-256 hash; the plain
// token is never stored.
export async function checkPhoneToken(ctx: QueryCtx | MutationCtx, token: string): Promise<{ id: Id<'tokens'>; name: string; expiresAt: number }> {
  const hash = await sha256(token);
  const row = await ctx.db
    .query('tokens')
    .withIndex('by_hash', (q) => q.eq('hash', hash))
    .unique();
  if (!row || row.revokedAt || row.expiresAt < Date.now()) throw new ConvexError({ kind: 'auth', message: 'bad or expired phone token' });
  return { id: row._id, name: row.name, expiresAt: row.expiresAt };
}

export async function sha256(text: string): Promise<string> {
  const data = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}
