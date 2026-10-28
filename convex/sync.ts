// What the runner writes (runner/src/sync.ts). Every mutation carries the
// runner key (lib.ts). Rows are current state, so writing the same thing
// twice is harmless, and a runner that was offline writes each changed
// row once when it's back.
import { v } from 'convex/values';
import { internalMutation, mutation, query } from './_generated/server';
import { internal } from './_generated/api';
import { threadFields, views } from './schema';
import { checkRunnerKey } from './lib';

// Text messages kept per thread (the phone's thread view); older ones go
// as new ones arrive, unless the phone asked for them (pagedAt).
export const MESSAGES_KEPT = 20;
// Finished commands and paged messages older than this are pruned.
const KEEP_FINISHED_MS = 24 * 60 * 60_000;

const threadDoc = v.object({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) });

// A push goes out when a thread starts needing Mike (needsYou goes from
// false to true), at most one per thread this often, so a status that
// flaps doesn't ring his phone over and over.
const PUSH_COOLDOWN_MS = 30_000;

export const upsertThreads = mutation({
  args: { key: v.string(), threads: v.array(threadDoc) },
  returns: v.null(),
  handler: async (ctx, { key, threads }) => {
    checkRunnerKey(key);
    const now = Date.now();
    for (const t of threads) {
      const existing = await ctx.db
        .query('threads')
        .withIndex('by_threadId', (q) => q.eq('threadId', t.threadId))
        .unique();
      const wantsPush = t.needsYou && existing !== null && !existing.needsYou && (existing.pushedAt ?? 0) < now - PUSH_COOLDOWN_MS;
      if (existing) await ctx.db.replace(existing._id, { ...t, ...(wantsPush ? { pushedAt: now } : existing.pushedAt ? { pushedAt: existing.pushedAt } : {}) });
      else await ctx.db.insert('threads', t);
      if (wantsPush) await ctx.scheduler.runAfter(0, internal.push.notify, { threadId: t.threadId });
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

// ------------------------------------------------------------ messages

const messageDoc = v.object({
  threadId: v.string(),
  seq: v.number(),
  role: v.union(v.literal('user'), v.literal('assistant')),
  text: v.string(),
  origin: v.optional(v.string()),
  at: v.string(),
  pagedAt: v.optional(v.number()), // the phone asked for it (loadEarlier); not counted in the newest 20, pruned after a day
});

// Adds text messages (one per persisted user.message or assistant.text,
// keyed by seq so writing one twice is harmless) and keeps the newest
// MESSAGES_KEPT per thread.
export const appendMessages = mutation({
  args: { key: v.string(), messages: v.array(messageDoc) },
  returns: v.null(),
  handler: async (ctx, { key, messages }) => {
    checkRunnerKey(key);
    const touched = new Set<string>();
    for (const m of messages) {
      const existing = await ctx.db
        .query('messages')
        .withIndex('by_thread_seq', (q) => q.eq('threadId', m.threadId).eq('seq', m.seq))
        .unique();
      if (existing) continue;
      await ctx.db.insert('messages', m);
      touched.add(m.threadId);
    }
    for (const threadId of touched) {
      const rows = await ctx.db
        .query('messages')
        .withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))
        .order('desc')
        .collect();
      let kept = 0;
      for (const row of rows) {
        if (row.pagedAt) continue;
        kept++;
        if (kept > MESSAGES_KEPT) await ctx.db.delete(row._id);
      }
    }
    return null;
  },
});

// The newest message seq per thread of a runner, so a runner starting up
// only sends what the mirror doesn't have.
export const messageHeads = query({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.array(v.object({ threadId: v.string(), lastSeq: v.number() })),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const t of ctx.db.query('threads').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
      const newest = await ctx.db
        .query('messages')
        .withIndex('by_thread_seq', (q) => q.eq('threadId', t.threadId))
        .order('desc')
        .first();
      if (newest) out.push({ threadId: t.threadId, lastSeq: newest.seq });
    }
    return out;
  },
});

// ------------------------------------------------------------ lists
// Projects, schedules and accounts: the runner sends its whole list each
// time one changes, and the rows of that runner are replaced.

const projectDoc = v.object({
  id: v.string(),
  title: v.string(),
  folders: v.array(v.string()),
  goals: v.string(),
  state: v.string(),
  notes: v.string(),
  createdBy: v.string(),
  archived: v.boolean(),
  createdAt: v.string(),
  updatedAt: v.string(),
  threadCount: v.number(),
  lastActivityAt: v.optional(v.string()),
});

const scheduleDoc = v.object({
  id: v.string(),
  title: v.string(),
  text: v.string(),
  at: v.optional(v.string()),
  cron: v.optional(v.string()),
  timezone: v.optional(v.string()),
  whenText: v.string(),
  threadId: v.optional(v.string()),
  cwd: v.optional(v.string()),
  accountId: v.optional(v.string()),
  model: v.optional(v.string()),
  paused: v.boolean(),
  createdAt: v.string(),
  updatedAt: v.string(),
  nextRunAt: v.optional(v.string()),
  finishedAt: v.optional(v.string()),
  runs: v.number(),
  lastRun: v.optional(v.object({ at: v.string(), outcome: v.string(), threadId: v.optional(v.string()), note: v.optional(v.string()) })),
});

const accountDoc = v.object({
  id: v.string(),
  provider: v.string(),
  title: v.string(),
  note: v.optional(v.string()),
  email: v.optional(v.string()),
  plan: v.optional(v.string()),
  defaultModel: v.optional(v.string()),
  usage: v.optional(
    v.object({
      windows: v.array(v.object({ kind: v.string(), title: v.string(), remainingPercent: v.number(), resetsAt: v.optional(v.string()), detail: v.optional(v.string()) })),
      readAt: v.string(),
      source: v.string(),
      stale: v.optional(v.boolean()),
      blocked: v.optional(v.boolean()),
      notice: v.optional(v.string()),
    }),
  ),
});

async function replaceRows(ctx: { db: any }, table: 'projects' | 'schedules' | 'accounts', runnerId: string, rows: Record<string, unknown>[]): Promise<void> {
  for await (const row of ctx.db.query(table).withIndex('by_runnerId', (q: any) => q.eq('runnerId', runnerId))) await ctx.db.delete(row._id);
  for (const row of rows) await ctx.db.insert(table, { ...row, runnerId });
}

export const setProjects = mutation({
  args: { key: v.string(), runnerId: v.string(), projects: v.array(projectDoc) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, projects }) => {
    checkRunnerKey(key);
    await replaceRows(ctx, 'projects', runnerId, projects);
    return null;
  },
});

export const setSchedules = mutation({
  args: { key: v.string(), runnerId: v.string(), schedules: v.array(scheduleDoc) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, schedules }) => {
    checkRunnerKey(key);
    await replaceRows(ctx, 'schedules', runnerId, schedules);
    return null;
  },
});

export const setAccounts = mutation({
  args: { key: v.string(), runnerId: v.string(), accounts: v.array(accountDoc) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, accounts }) => {
    checkRunnerKey(key);
    await replaceRows(ctx, 'accounts', runnerId, accounts);
    return null;
  },
});

// ------------------------------------------------------------ commands
// What the phone asked for (phone.ts). The owning runner subscribes to
// pendingCommands, takes each one (once: takeCommand says no the second
// time), applies it through the same code the Mac app uses, and finishes
// it with the outcome.

export const pendingCommands = query({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.array(v.object({ commandId: v.id('commands'), kind: v.string(), threadId: v.optional(v.string()), args: v.any(), createdAt: v.number() })),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const out = [];
    for (const target of [runnerId, 'any']) {
      for await (const c of ctx.db.query('commands').withIndex('by_runner_state', (q) => q.eq('runnerId', target).eq('state', 'pending'))) {
        out.push({ commandId: c._id, kind: c.kind, ...(c.threadId ? { threadId: c.threadId } : {}), args: c.args, createdAt: c.createdAt });
      }
    }
    return out.sort((a, b) => a.createdAt - b.createdAt);
  },
});

export const takeCommand = mutation({
  args: { key: v.string(), commandId: v.id('commands') },
  returns: v.boolean(),
  handler: async (ctx, { key, commandId }) => {
    checkRunnerKey(key);
    const c = await ctx.db.get(commandId);
    if (!c || c.state !== 'pending') return false;
    await ctx.db.patch(commandId, { state: 'taken', takenAt: Date.now() });
    return true;
  },
});

export const finishCommand = mutation({
  args: { key: v.string(), commandId: v.id('commands'), ok: v.boolean(), note: v.optional(v.string()), resultThreadId: v.optional(v.string()) },
  returns: v.null(),
  handler: async (ctx, { key, commandId, ok, note, resultThreadId }) => {
    checkRunnerKey(key);
    const c = await ctx.db.get(commandId);
    if (!c) return null;
    await ctx.db.patch(commandId, { state: ok ? 'done' : 'failed', doneAt: Date.now(), ...(note ? { note } : {}), ...(resultThreadId ? { resultThreadId } : {}) });
    return null;
  },
});

// Finished commands and paged messages older than a day go (crons.ts).
export const pruneOld = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const cutoff = Date.now() - KEEP_FINISHED_MS;
    for (const state of ['done', 'failed'] as const) {
      for await (const c of ctx.db.query('commands').withIndex('by_state', (q) => q.eq('state', state))) {
        if ((c.doneAt ?? c.createdAt) < cutoff) await ctx.db.delete(c._id);
      }
    }
    for await (const m of ctx.db.query('messages')) {
      if (m.pagedAt && m.pagedAt < cutoff) await ctx.db.delete(m._id);
    }
    return null;
  },
});
