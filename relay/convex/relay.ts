// The relay's records: installs and the daily counts (schema.ts).
import { ConvexError, v } from 'convex/values';
import { internalMutation, internalQuery } from './_generated/server';

// Per install, so one runaway backend can't flood anyone's phone or Apple.
export const SENDS_PER_HOUR = 120;
// New installs per UTC day across everyone, against someone scripting it.
export const REGISTRATIONS_PER_DAY = 500;

export const day = (ms = Date.now()) => new Date(ms).toISOString().slice(0, 10);

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

function randomHex(bytes: number): string {
  const a = new Uint8Array(bytes);
  crypto.getRandomValues(a);
  return Array.from(a, (b) => b.toString(16).padStart(2, '0')).join('');
}

export const register = internalMutation({
  args: { version: v.optional(v.string()) },
  returns: v.object({ installId: v.string(), installKey: v.string() }),
  handler: async (ctx, { version }) => {
    const today = day();
    const counts = await ctx.db
      .query('days')
      .withIndex('by_day', (q) => q.eq('day', today))
      .unique();
    if ((counts?.registrations ?? 0) >= REGISTRATIONS_PER_DAY) throw new ConvexError({ kind: 'busy', message: 'too many new installs today; try again tomorrow' });
    const installId = 'i_' + randomHex(12);
    const installKey = 'k_' + randomHex(24);
    const now = Date.now();
    await ctx.db.insert('installs', { installId, keyHash: await sha256(installKey), createdAt: now, lastSeenAt: now, ...(version ? { version: version.slice(0, 40) } : {}), hourStart: now, hourSends: 0 });
    if (counts) await ctx.db.patch(counts._id, { registrations: counts.registrations + 1 });
    else await ctx.db.insert('days', { day: today, sends: 0, failed: 0, registrations: 1 });
    return { installId, installKey };
  },
});

// Checks the install's key and rate limit, and counts the send.
export const admit = internalMutation({
  args: { installId: v.string(), installKey: v.string(), version: v.optional(v.string()) },
  returns: v.union(v.literal('ok'), v.literal('auth'), v.literal('limited')),
  handler: async (ctx, { installId, installKey, version }) => {
    const row = await ctx.db
      .query('installs')
      .withIndex('by_installId', (q) => q.eq('installId', installId))
      .unique();
    if (!row || row.keyHash !== (await sha256(installKey))) return 'auth';
    const now = Date.now();
    const fresh = now - row.hourStart >= 3_600_000;
    const sends = fresh ? 0 : row.hourSends;
    if (sends >= SENDS_PER_HOUR) return 'limited';
    await ctx.db.patch(row._id, { lastSeenAt: now, hourStart: fresh ? now : row.hourStart, hourSends: sends + 1, ...(version ? { version: version.slice(0, 40) } : {}) });
    return 'ok';
  },
});

export const counted = internalMutation({
  args: { ok: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { ok }) => {
    const today = day();
    const counts = await ctx.db
      .query('days')
      .withIndex('by_day', (q) => q.eq('day', today))
      .unique();
    const add = { sends: ok ? 1 : 0, failed: ok ? 0 : 1 };
    if (counts) await ctx.db.patch(counts._id, { sends: counts.sends + add.sends, failed: counts.failed + add.failed });
    else await ctx.db.insert('days', { day: today, registrations: 0, ...add });
    return null;
  },
});

// For Mike: `npx convex run relay:stats --prod`.
export const stats = internalQuery({
  args: {},
  returns: v.object({ installs: v.number(), activeLast7Days: v.number(), versions: v.record(v.string(), v.number()), days: v.array(v.object({ day: v.string(), sends: v.number(), failed: v.number(), registrations: v.number() })) }),
  handler: async (ctx) => {
    const weekAgo = Date.now() - 7 * 86_400_000;
    let installs = 0;
    let active = 0;
    const versions: Record<string, number> = {};
    for await (const i of ctx.db.query('installs')) {
      installs++;
      if (i.lastSeenAt >= weekAgo) active++;
      const key = i.version ?? 'unknown';
      versions[key] = (versions[key] ?? 0) + 1;
    }
    const days = (await ctx.db.query('days').withIndex('by_day').order('desc').take(14)).map(({ day, sends, failed, registrations }) => ({ day, sends, failed, registrations }));
    return { installs, activeLast7Days: active, versions, days };
  },
});

// Removes an install, for someone asking to be forgotten (or a test):
//   npx convex run relay:forget '{"installId":"i_..."}' --prod
export const forget = internalMutation({
  args: { installId: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { installId }) => {
    const row = await ctx.db
      .query('installs')
      .withIndex('by_installId', (q) => q.eq('installId', installId))
      .unique();
    if (row) await ctx.db.delete(row._id);
    return Boolean(row);
  },
});

// Wipes the test day's counts too, when there was nothing real in it.
export const resetDay = internalMutation({
  args: { day: v.string() },
  returns: v.null(),
  handler: async (ctx, { day }) => {
    const row = await ctx.db
      .query('days')
      .withIndex('by_day', (q) => q.eq('day', day))
      .unique();
    if (row) await ctx.db.delete(row._id);
    return null;
  },
});
