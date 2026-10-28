// The phones registered for push (phone:registerDevice), as push.ts
// needs them, and the thread a push is about.
import { v } from 'convex/values';
import { internalMutation, internalQuery } from './_generated/server';

export const targets = internalQuery({
  args: {},
  returns: v.array(v.object({ apnsToken: v.string(), environment: v.union(v.literal('sandbox'), v.literal('production')) })),
  handler: async (ctx) => {
    const out = [];
    for await (const d of ctx.db.query('devices')) out.push({ apnsToken: d.apnsToken, environment: d.environment });
    return out;
  },
});

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
  returns: v.union(v.null(), v.object({ title: v.string(), status: v.string(), preview: v.string(), needsYou: v.boolean(), pendingApproval: v.optional(v.any()) })),
  handler: async (ctx, { threadId }) => {
    const t = await ctx.db
      .query('threads')
      .withIndex('by_threadId', (q) => q.eq('threadId', threadId))
      .unique();
    if (!t) return null;
    return { title: t.title, status: t.status, preview: t.preview, needsYou: t.needsYou, ...(t.pendingApproval ? { pendingApproval: t.pendingApproval } : {}) };
  },
});

export const list = internalQuery({
  args: {},
  returns: v.array(v.object({ environment: v.string(), tokenName: v.string(), updatedAt: v.string(), tokenTail: v.string() })),
  handler: async (ctx) => {
    const out = [];
    for await (const d of ctx.db.query('devices')) out.push({ environment: d.environment, tokenName: d.tokenName, updatedAt: new Date(d.updatedAt).toISOString(), tokenTail: d.apnsToken.slice(-6) });
    return out;
  },
});
