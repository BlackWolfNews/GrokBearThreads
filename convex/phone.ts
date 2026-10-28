// The phone's API (ios/, thread f5247e5b). Every function takes the phone
// token and throws ConvexError({ kind: "auth" }) for a bad or expired one.
// Queries read the mirror; mutations only ever add a row to `commands`,
// which the owning runner applies (step 3 of docs/convex-backend.md) and
// marks done or failed. Nothing here touches a runner directly.
import { ConvexError, v } from 'convex/values';
import { mutation, query, type QueryCtx } from './_generated/server';
import { threadFields, views } from './schema';
import { checkPhoneToken } from './lib';
import { API_VERSION } from './version';

// A runner not heard from for this long is offline, and a command with no
// runnerId goes to the newest one still online.
const ONLINE_MS = 3 * 60_000;
const DEN_LIMIT = 100;

const row = v.object({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) });
const message = v.object({ seq: v.number(), role: v.union(v.literal('user'), v.literal('assistant')), text: v.string(), origin: v.optional(v.string()), at: v.string() });

function strip<T extends { _id: unknown; _creationTime: unknown }>(doc: T): Omit<T, '_id' | '_creationTime'> {
  const { _id, _creationTime, ...rest } = doc;
  return rest;
}

// A thread row as the phone sees it. pushedAt is the mirror's own (push.ts)
// and isn't in `row`: returning it fails the query's validator, which broke
// the lists for every thread that had sent a push.
function stripThread<T extends { _id: unknown; _creationTime: unknown; pushedAt?: number }>(doc: T): Omit<T, '_id' | '_creationTime' | 'pushedAt'> {
  const { _id, _creationTime, pushedAt, ...rest } = doc;
  return rest;
}

// apiVersion is the backend's (version.ts), so the app can say "update
// Threadbear on your Mac" when it's talking to a backend older than it needs.
export const me = query({
  args: { token: v.string() },
  returns: v.object({ name: v.string(), expiresAt: v.string(), apiVersion: v.number() }),
  handler: async (ctx, { token }) => {
    const t = await checkPhoneToken(ctx, token);
    return { name: t.name, expiresAt: new Date(t.expiresAt).toISOString(), apiVersion: API_VERSION };
  },
});

export const runners = query({
  args: { token: v.string() },
  returns: v.array(v.object({ runnerId: v.string(), name: v.string(), version: v.string(), lastSeenAt: v.string(), draining: v.boolean() })),
  handler: async (ctx, { token }) => {
    await checkPhoneToken(ctx, token);
    const out = [];
    for await (const r of ctx.db.query('runners')) {
      out.push({ runnerId: r.runnerId, name: r.name, version: r.version, lastSeenAt: new Date(r.lastSeenAt).toISOString(), draining: r.draining });
    }
    return out;
  },
});

// Newest activity first. The den is capped at DEN_LIMIT.
export const threads = query({
  args: { token: v.string(), view: v.union(...views.map((x) => v.literal(x))) },
  returns: v.array(row),
  handler: async (ctx, { token, view }) => {
    await checkPhoneToken(ctx, token);
    const q = ctx.db
      .query('threads')
      .withIndex('by_view_activity', (x) => x.eq('view', view))
      .order('desc');
    const rows = view === 'den' ? await q.take(DEN_LIMIT) : await q.collect();
    return rows.map(stripThread);
  },
});

export const thread = query({
  args: { token: v.string(), threadId: v.string() },
  returns: v.object({ thread: row, messages: v.array(message) }),
  handler: async (ctx, { token, threadId }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    const messages = [];
    for await (const m of ctx.db.query('messages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) {
      messages.push({ seq: m.seq, role: m.role, text: m.text, ...(m.origin ? { origin: m.origin } : {}), at: m.at });
    }
    return { thread: stripThread(t), messages };
  },
});

export const command = query({
  args: { token: v.string(), commandId: v.id('commands') },
  returns: v.object({ state: v.union(v.literal('pending'), v.literal('taken'), v.literal('done'), v.literal('failed')), note: v.optional(v.string()), threadId: v.optional(v.string()) }),
  handler: async (ctx, { token, commandId }) => {
    await checkPhoneToken(ctx, token);
    const c = await ctx.db.get(commandId);
    if (!c) throw new ConvexError({ kind: 'notFound', message: 'no such command' });
    return { state: c.state, ...(c.note ? { note: c.note } : {}), ...(c.resultThreadId ? { threadId: c.resultThreadId } : {}) };
  },
});

export const projects = query({
  args: { token: v.string(), archived: v.optional(v.boolean()) },
  returns: v.array(v.object({ runnerId: v.string(), id: v.string(), title: v.string(), folders: v.array(v.string()), goals: v.string(), state: v.string(), notes: v.string(), createdBy: v.string(), archived: v.boolean(), createdAt: v.string(), updatedAt: v.string(), threadCount: v.number(), lastActivityAt: v.optional(v.string()) })),
  handler: async (ctx, { token, archived }) => {
    await checkPhoneToken(ctx, token);
    const out = [];
    for await (const p of ctx.db.query('projects')) {
      if (p.archived && !archived) continue;
      out.push(strip(p));
    }
    return out.sort((a, b) => (b.lastActivityAt ?? b.updatedAt).localeCompare(a.lastActivityAt ?? a.updatedAt));
  },
});

export const schedules = query({
  args: { token: v.string() },
  returns: v.array(v.any()),
  handler: async (ctx, { token }) => {
    await checkPhoneToken(ctx, token);
    const out = [];
    for await (const s of ctx.db.query('schedules')) out.push(strip(s));
    return out;
  },
});

export const accounts = query({
  args: { token: v.string() },
  returns: v.array(v.any()),
  handler: async (ctx, { token }) => {
    await checkPhoneToken(ctx, token);
    const out = [];
    for await (const a of ctx.db.query('accounts')) out.push(strip(a));
    return out;
  },
});

// ------------------------------------------------------------ mutations

export const send = mutation({
  args: { token: v.string(), threadId: v.string(), text: v.string() },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, text }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'send', threadId, { text });
  },
});

export const respond = mutation({
  args: { token: v.string(), threadId: v.string(), approvalId: v.string(), decision: v.union(v.literal('allow'), v.literal('allowAlways'), v.literal('deny')), message: v.optional(v.string()) },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, approvalId, decision, message }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'respond', threadId, { approvalId, decision, ...(message ? { message } : {}) });
  },
});

// A question's answers, one per question keyed by its text (what the
// runner's approvals.respond takes with decision "answered"); `message` is
// the chosen answers in one line for the transcript.
export const answer = mutation({
  args: { token: v.string(), threadId: v.string(), approvalId: v.string(), answers: v.record(v.string(), v.string()), message: v.optional(v.string()) },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, approvalId, answers, message }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'respond', threadId, { approvalId, decision: 'answered', answers, message: message ?? Object.values(answers).join('; ') });
  },
});

export const update = mutation({
  args: {
    token: v.string(),
    threadId: v.string(),
    change: v.union(
      v.object({ snooze: v.object({ until: v.optional(v.string()), untilRestart: v.optional(v.boolean()) }) }),
      v.object({ wake: v.literal(true) }),
      v.object({ archive: v.literal(true) }),
      v.object({ unarchive: v.literal(true) }),
      v.object({ markSeen: v.literal(true) }),
      v.object({ title: v.string() }),
    ),
  },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, change }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'update', threadId, change);
  },
});

// A new thread. With no runnerId, the newest runner still online takes it
// (or the first one back, as "any").
export const create = mutation({
  args: { token: v.string(), text: v.string(), runnerId: v.optional(v.string()), cwd: v.optional(v.string()), accountId: v.optional(v.string()), model: v.optional(v.string()) },
  returns: v.id('commands'),
  handler: async (ctx, { token, text, runnerId, cwd, accountId, model }) => {
    await checkPhoneToken(ctx, token);
    let target = runnerId;
    if (!target) {
      let best: { runnerId: string; lastSeenAt: number } | undefined;
      for await (const r of ctx.db.query('runners')) {
        if (r.draining || Date.now() - r.lastSeenAt > ONLINE_MS) continue;
        if (!best || r.lastSeenAt > best.lastSeenAt) best = r;
      }
      target = best?.runnerId ?? 'any';
    }
    return queue(ctx, target, 'create', undefined, { text, ...(cwd ? { cwd } : {}), ...(accountId ? { accountId } : {}), ...(model ? { model } : {}) });
  },
});

// Older messages: the owning runner writes up to 50 text messages before
// `beforeSeq` as paged rows (phone:thread then returns them too; they go
// after a day). The row's `earliestSeq` says whether there are any.
export const loadEarlier = mutation({
  args: { token: v.string(), threadId: v.string(), beforeSeq: v.number() },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, beforeSeq }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'page', threadId, { beforeSeq });
  },
});

export const registerDevice = mutation({
  args: { token: v.string(), apnsToken: v.string(), environment: v.union(v.literal('sandbox'), v.literal('production')) },
  returns: v.null(),
  handler: async (ctx, { token, apnsToken, environment }) => {
    const t = await checkPhoneToken(ctx, token);
    const existing = await ctx.db
      .query('devices')
      .withIndex('by_apnsToken', (q) => q.eq('apnsToken', apnsToken))
      .unique();
    const row = { apnsToken, environment, tokenName: t.name, updatedAt: Date.now() };
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert('devices', row);
    return null;
  },
});

async function findThread(ctx: QueryCtx, threadId: string) {
  const t = await ctx.db
    .query('threads')
    .withIndex('by_threadId', (q) => q.eq('threadId', threadId))
    .unique();
  if (!t) throw new ConvexError({ kind: 'notFound', message: 'no such thread' });
  return t;
}

async function queue(ctx: { db: QueryCtx['db'] & { insert: any } }, runnerId: string, kind: 'send' | 'respond' | 'update' | 'create' | 'page', threadId: string | undefined, args: Record<string, unknown>) {
  return ctx.db.insert('commands', { runnerId, ...(threadId ? { threadId } : {}), kind, args, state: 'pending', createdAt: Date.now() });
}
