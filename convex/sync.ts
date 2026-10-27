// What the runner writes (runner/src/sync.ts). Every mutation carries the
// runner key (lib.ts). Rows are current state, so writing the same thing
// twice is harmless, and a runner that was offline writes each changed
// row once when it's back.
import { v } from 'convex/values';
import { mutation, query } from './_generated/server';
import { threadFields, views } from './schema';
import { checkRunnerKey } from './lib';

const threadDoc = v.object({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) });

export const upsertThreads = mutation({
  args: { key: v.string(), threads: v.array(threadDoc) },
  returns: v.null(),
  handler: async (ctx, { key, threads }) => {
    checkRunnerKey(key);
    for (const t of threads) {
      const existing = await ctx.db
        .query('threads')
        .withIndex('by_threadId', (q) => q.eq('threadId', t.threadId))
        .unique();
      if (existing) await ctx.db.replace(existing._id, t);
      else await ctx.db.insert('threads', t);
    }
    return null;
  },
});

export const removeThreads = mutation({
  args: { key: v.string(), threadIds: v.array(v.string()) },
  returns: v.null(),
  handler: async (ctx, { key, threadIds }) => {
    checkRunnerKey(key);
    for (const threadId of threadIds) {
      const row = await ctx.db
        .query('threads')
        .withIndex('by_threadId', (q) => q.eq('threadId', threadId))
        .unique();
      if (row) await ctx.db.delete(row._id);
      for await (const m of ctx.db.query('messages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) await ctx.db.delete(m._id);
    }
    return null;
  },
});

// After a runner has written everything it has: rows of its that it no
// longer knows (deleted while it was offline) go.
export const prune = mutation({
  args: { key: v.string(), runnerId: v.string(), keep: v.array(v.string()) },
  returns: v.number(),
  handler: async (ctx, { key, runnerId, keep }) => {
    checkRunnerKey(key);
    const keepSet = new Set(keep);
    let n = 0;
    for await (const row of ctx.db.query('threads').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
      if (keepSet.has(row.threadId)) continue;
      await ctx.db.delete(row._id);
      n++;
    }
    return n;
  },
});

export const heartbeat = mutation({
  args: {
    key: v.string(),
    runner: v.object({
      runnerId: v.string(),
      name: v.string(),
      version: v.string(),
      release: v.optional(v.string()),
      startedAt: v.string(),
      draining: v.boolean(),
      threadCount: v.number(),
    }),
  },
  returns: v.null(),
  handler: async (ctx, { key, runner }) => {
    checkRunnerKey(key);
    const row = { ...runner, lastSeenAt: Date.now() };
    const existing = await ctx.db
      .query('runners')
      .withIndex('by_runnerId', (q) => q.eq('runnerId', runner.runnerId))
      .unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert('runners', row);
    return null;
  },
});

// A runner stopping for good (not handing over) says so, so the phone
// shows it offline at once rather than 3 minutes later.
export const bye = mutation({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.null(),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const existing = await ctx.db
      .query('runners')
      .withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))
      .unique();
    if (existing) await ctx.db.patch(existing._id, { lastSeenAt: 0 });
    return null;
  },
});

// For the runner's own checks and tests: what's mirrored for a runner.
export const threadsOf = query({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.array(v.object({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) })),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const row of ctx.db.query('threads').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
      const { _id, _creationTime, ...rest } = row;
      out.push(rest);
    }
    return out;
  },
});

export const runnersList = query({
  args: { key: v.string() },
  returns: v.array(v.object({ runnerId: v.string(), name: v.string(), version: v.string(), release: v.optional(v.string()), startedAt: v.string(), draining: v.boolean(), threadCount: v.number(), lastSeenAt: v.number() })),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const row of ctx.db.query('runners')) {
      const { _id, _creationTime, ...rest } = row;
      out.push(rest);
    }
    return out;
  },
});
