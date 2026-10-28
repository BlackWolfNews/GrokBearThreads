// The phones registered for push (phone:registerDevice), as push.ts
// needs them, and the thread a push is about.
import { v } from 'convex/values';
import { internalMutation, internalQuery } from './_generated/server';

export const targets = internalQuery({
  args: {},
  returns: v.array(v.object({ apnsToken: v.string(), environment: v.union(v.literal('sandbox'), v.literal('production')), notify: v.union(v.literal('away'), v.literal('always'), v.literal('off')), pushKey: v.optional(v.string()) })),
  handler: async (ctx) => {
    const out = [];
    for await (const d of ctx.db.query('devices')) out.push({ apnsToken: d.apnsToken, environment: d.environment, notify: d.notify ?? ('away' as const), ...(d.pushKey ? { pushKey: d.pushKey } : {}) });
    return out;
  },
});

export const relayInstall = internalQuery({
  args: { url: v.string() },
  returns: v.union(v.null(), v.object({ installId: v.string(), installKey: v.string() })),
  handler: async (ctx, { url }) => {
    const row = await ctx.db.query('relayInstall').first();
    return row && row.url === url ? { installId: row.installId, installKey: row.installKey } : null;
  },
});

// Replaces any earlier registration (a new relay URL, or one it forgot).
export const saveRelayInstall = internalMutation({
  args: { installId: v.string(), installKey: v.string(), url: v.string() },
  returns: v.null(),
  handler: async (ctx, a) => {
    for await (const row of ctx.db.query('relayInstall')) await ctx.db.delete(row._id);
    await ctx.db.insert('relayInstall', { ...a, createdAt: Date.now() });
    return null;
  },
});

export const clearRelayInstall = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    for await (const row of ctx.db.query('relayInstall')) await ctx.db.delete(row._id);
    return null;
  },
});

// Marks a thread's push as held for "away" phones while Mike is at the Mac;
// sync:setPresence sends it when he leaves.
export const holdPush = internalMutation({
  args: { threadId: v.string() },
  returns: v.null(),
  handler: async (ctx, { threadId }) => {
    const t = await ctx.db
      .query('threads')
      .withIndex('by_threadId', (q) => q.eq('threadId', threadId))
      .unique();
    if (t && t.needsYou) await ctx.db.patch(t._id, { pushHeldAt: Date.now() });
    return null;
  },
});

// A runner's word that Mike is at its Mac counts while it's still checking
// in; a Mac that's asleep or offline counts as away.
const PRESENCE_FRESH_MS = 3 * 60_000;

// Apple said the token is gone (the app was removed, or it's stale).
export const drop = internalMutation({
  args: { apnsToken: v.string() },
  returns: v.null(),
  handler: async (ctx, { apnsToken }) => {
    const row = await ctx.db
      .query('devices')
      .withIndex('by_apnsToken', (q) => q.eq('apnsToken', apnsToken))
      .unique();
    if (row) await ctx.db.delete(row._id);
    return null;
  },
});

export const threadForPush = internalQuery({
  args: { threadId: v.string() },
  returns: v.union(v.null(), v.object({ title: v.string(), status: v.string(), preview: v.string(), needsYou: v.boolean(), atMac: v.boolean(), pendingApproval: v.optional(v.any()) })),
  handler: async (ctx, { threadId }) => {
    const t = await ctx.db
      .query('threads')
      .withIndex('by_threadId', (q) => q.eq('threadId', threadId))
      .unique();
    if (!t) return null;
    const runner = await ctx.db
      .query('runners')
      .withIndex('by_runnerId', (q) => q.eq('runnerId', t.runnerId))
      .unique();
    const atMac = Boolean(runner?.atMac) && Date.now() - (runner?.lastSeenAt ?? 0) < PRESENCE_FRESH_MS;
    return { title: t.title, status: t.status, preview: t.preview, needsYou: t.needsYou, atMac, ...(t.pendingApproval ? { pendingApproval: t.pendingApproval } : {}) };
  },
});

export const list = internalQuery({
  args: {},
  returns: v.array(v.object({ environment: v.string(), tokenName: v.string(), updatedAt: v.string(), tokenTail: v.string(), notify: v.string() })),
  handler: async (ctx) => {
    const out = [];
    for await (const d of ctx.db.query('devices')) out.push({ environment: d.environment, tokenName: d.tokenName, updatedAt: new Date(d.updatedAt).toISOString(), tokenTail: d.apnsToken.slice(-6), notify: d.notify ?? 'away' });
    return out;
  },
});
