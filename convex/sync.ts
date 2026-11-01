// What the runner writes (runner/src/sync.ts). Every mutation carries the
// runner key (lib.ts). Rows are current state, so writing the same thing
// twice is harmless, and a runner that was offline writes each changed
// row once when it's back.
import { ConvexError, v } from 'convex/values';
import { internalMutation, mutation, query, type MutationCtx } from './_generated/server';
import { internal } from './_generated/api';
import { threadFields, views } from './schema';
import { API_VERSION } from './version';
import { checkRunnerKey } from './lib';
import { issueToken as makeToken, listTokens as allTokens, revokeToken as revokeOne, tokenInfo, tokenKind, MAX_DAYS } from './tokens';

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
      // A held push stays held only while the thread still needs Mike.
      const held = t.needsYou && existing?.pushHeldAt && !wantsPush ? { pushHeldAt: existing.pushHeldAt } : {};
      if (existing) await ctx.db.replace(existing._id, { ...t, ...(wantsPush ? { pushedAt: now } : existing.pushedAt ? { pushedAt: existing.pushedAt } : {}), ...held });
      else await ctx.db.insert('threads', t);
      if (wantsPush) await ctx.scheduler.runAfter(0, internal.push.notify, { threadId: t.threadId });
    }
    return null;
  },
});

// Whether Mike is at this runner's Mac, sent by the runner when it changes
// (API 3). Leaving sends the pushes that were held back while he was there,
// for threads that still need him.
export const setPresence = mutation({
  args: { key: v.string(), runnerId: v.string(), atMac: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, atMac }) => {
    checkRunnerKey(key);
    const runner = await ctx.db
      .query('runners')
      .withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))
      .unique();
    if (runner) await ctx.db.patch(runner._id, { atMac, atMacAt: Date.now() });
    if (atMac) return null;
    for await (const t of ctx.db.query('threads').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
      if (!t.pushHeldAt) continue;
      await ctx.db.patch(t._id, { pushHeldAt: undefined });
      if (t.needsYou) await ctx.scheduler.runAfter(0, internal.push.notify, { threadId: t.threadId, held: true });
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
      await dropImages(ctx, threadId);
      for await (const img of ctx.db.query('replyImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) {
        await ctx.storage.delete(img.storageId);
        await ctx.db.delete(img._id);
      }
    }
    return null;
  },
});

// ------------------------------------------------------------ reply pictures
// What an agent showed Mike, for the phone (API 24; schema.ts, replyImages):
// the runner asks what's up (replyImages), uploads each new file to an upload
// URL (iconUploadUrl) and records it (addReplyImage).

export const replyImages = query({
  args: { key: v.string(), threadId: v.string() },
  returns: v.array(v.object({ seq: v.number(), path: v.string() })),
  handler: async (ctx, { key, threadId }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const img of ctx.db.query('replyImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) out.push({ seq: img.seq, path: img.path });
    return out;
  },
});

export const addReplyImage = mutation({
  args: {
    key: v.string(),
    threadId: v.string(),
    seq: v.number(),
    path: v.string(),
    src: v.optional(v.string()),
    pinned: v.optional(v.boolean()),
    storageId: v.id('_storage'),
    mediaType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  returns: v.null(),
  handler: async (ctx, { key, ...img }) => {
    checkRunnerKey(key);
    // Sent twice (a retry after a lost reply): keep the first, drop the copy.
    const same = await ctx.db
      .query('replyImages')
      .withIndex('by_thread_seq', (q) => q.eq('threadId', img.threadId).eq('seq', img.seq))
      .filter((q) => q.eq(q.field('path'), img.path))
      .first();
    if (same) await ctx.storage.delete(img.storageId);
    else await ctx.db.insert('replyImages', img);
    return null;
  },
});

// ------------------------------------------------------------ shared pictures
// A shared thread's pictures (API 8; docs/website.md, "Sharing"): the runner
// asks what's up (shareImages), uploads each new file to an upload URL
// (iconUploadUrl serves for these too) and records it (addShareImage).
// When the thread stops being shared it drops them all.

async function dropImages(ctx: MutationCtx, threadId: string): Promise<number> {
  let n = 0;
  for await (const img of ctx.db.query('shareImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) {
    await ctx.storage.delete(img.storageId);
    await ctx.db.delete(img._id);
    n++;
  }
  return n;
}

export const shareImages = query({
  args: { key: v.string(), threadId: v.string() },
  returns: v.array(v.object({ seq: v.number(), path: v.string() })),
  handler: async (ctx, { key, threadId }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const img of ctx.db.query('shareImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId))) out.push({ seq: img.seq, path: img.path });
    return out;
  },
});

export const addShareImage = mutation({
  args: {
    key: v.string(),
    threadId: v.string(),
    seq: v.number(),
    path: v.string(),
    src: v.optional(v.string()),
    storageId: v.id('_storage'),
    mediaType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  returns: v.null(),
  handler: async (ctx, { key, ...img }) => {
    checkRunnerKey(key);
    // Sent twice (a retry after a lost reply): keep the first, drop the copy.
    const same = await ctx.db
      .query('shareImages')
      .withIndex('by_thread_seq', (q) => q.eq('threadId', img.threadId).eq('seq', img.seq))
      .filter((q) => q.eq(q.field('path'), img.path))
      .first();
    if (same) await ctx.storage.delete(img.storageId);
    else await ctx.db.insert('shareImages', img);
    return null;
  },
});

export const dropShareImages = mutation({
  args: { key: v.string(), threadId: v.string() },
  returns: v.number(),
  handler: async (ctx, { key, threadId }) => {
    checkRunnerKey(key);
    return dropImages(ctx, threadId);
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
      icon: v.optional(v.string()),
      rpcUrl: v.optional(v.string()),
    }),
  },
  // The backend's API version (version.ts), so the runner can tell when it's
  // talking to an older backend than it was built for.
  returns: v.object({ apiVersion: v.number() }),
  handler: async (ctx, { key, runner }) => {
    checkRunnerKey(key);
    const row = { ...runner, lastSeenAt: Date.now() };
    const existing = await ctx.db
      .query('runners')
      .withIndex('by_runnerId', (q) => q.eq('runnerId', runner.runnerId))
      .unique();
    // Presence is setPresence's to change; a heartbeat keeps it.
    if (existing) await ctx.db.replace(existing._id, { ...row, ...(existing.atMac !== undefined ? { atMac: existing.atMac, atMacAt: existing.atMacAt } : {}) });
    else await ctx.db.insert('runners', row);
    return { apiVersion: API_VERSION };
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
  returns: v.array(
    v.object({
      runnerId: v.string(),
      name: v.string(),
      version: v.string(),
      release: v.optional(v.string()),
      startedAt: v.string(),
      draining: v.boolean(),
      threadCount: v.number(),
      lastSeenAt: v.number(),
      icon: v.optional(v.string()),
    }),
  ),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    const out = [];
    // Picked by name: the row keeps fields of its own (atMac and atMacAt,
    // from setPresence), and returning one fails the validator.
    for await (const r of ctx.db.query('runners')) {
      out.push({
        runnerId: r.runnerId,
        name: r.name,
        version: r.version,
        ...(r.release !== undefined ? { release: r.release } : {}),
        startedAt: r.startedAt,
        draining: r.draining,
        threadCount: r.threadCount,
        lastSeenAt: r.lastSeenAt,
        ...(r.icon !== undefined ? { icon: r.icon } : {}),
      });
    }
    return out;
  },
});

// ------------------------------------------------------------ tokens
// The Mac app's Settings › Phone & browser, through the runner (API 6;
// docs/protocol.md "Devices"): issues the token a new phone or browser
// holds, lists them, revokes one. The plain token goes back in the reply
// that issued it and nowhere else.

export const issueToken = mutation({
  args: { key: v.string(), kind: tokenKind, name: v.string(), days: v.optional(v.number()) },
  returns: v.object({ id: v.string(), token: v.string(), expiresAt: v.string() }),
  handler: async (ctx, { key, kind, name, days }) => {
    checkRunnerKey(key);
    const trimmed = name.trim().slice(0, 80);
    if (!trimmed) throw new ConvexError({ kind: 'badArgs', message: 'name must not be blank' });
    if (days !== undefined && (!Number.isFinite(days) || days < 1 || days > MAX_DAYS)) throw new ConvexError({ kind: 'badArgs', message: `days must be 1 to ${MAX_DAYS}` });
    return makeToken(ctx, { kind, name: trimmed, days });
  },
});

export const listTokens = query({
  args: { key: v.string() },
  returns: v.array(tokenInfo),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    return allTokens(ctx);
  },
});

export const revokeToken = mutation({
  args: { key: v.string(), id: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { key, id }) => {
    checkRunnerKey(key);
    return revokeOne(ctx, id);
  },
});

// ------------------------------------------------------------ messages

const messageDoc = v.object({
  threadId: v.string(),
  seq: v.number(),
  role: v.union(v.literal('user'), v.literal('assistant'), v.literal('tool')),
  text: v.string(),
  origin: v.optional(v.string()),
  toolKind: v.optional(v.string()),
  summary: v.optional(v.boolean()), // API 14
  at: v.string(),
  pagedAt: v.optional(v.number()), // an old phone asked for it (loadEarlier): phone:thread shows it for a day
});

// Adds messages (text, and one line per tool call), keyed by seq so writing
// one twice is harmless. Every message is kept (until API 2 only the newest
// 20 were). A row sent again with pagedAt is an old phone's "Load earlier
// messages", so the mark goes on the row that's already there.
export const appendMessages = mutation({
  args: { key: v.string(), messages: v.array(messageDoc) },
  returns: v.null(),
  handler: async (ctx, { key, messages }) => {
    checkRunnerKey(key);
    for (const m of messages) {
      const existing = await ctx.db
        .query('messages')
        .withIndex('by_thread_seq', (q) => q.eq('threadId', m.threadId).eq('seq', m.seq))
        .unique();
      if (!existing) await ctx.db.insert('messages', m);
      else if (m.pagedAt && !existing.pagedAt) await ctx.db.patch(existing._id, { pagedAt: m.pagedAt });
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
  icon: v.optional(v.object({ symbol: v.optional(v.string()), picture: v.optional(v.string()), by: v.string() })),
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
  // API 20: what the phone's new thread pickers offer.
  models: v.optional(v.array(v.object({ id: v.string(), title: v.string(), effortLevels: v.optional(v.array(v.string())), defaultEffort: v.optional(v.string()) }))),
  defaultEffort: v.optional(v.string()),
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
    // A picture for a project that's gone, or that has no picture any more,
    // goes with it. One the runner hasn't replaced yet stays, so the phone
    // keeps showing the old picture rather than a letter meanwhile.
    const wanted = new Set(projects.filter((p) => p.icon?.picture).map((p) => p.id));
    for await (const row of ctx.db.query('projectIcons').withIndex('by_runner_project', (q) => q.eq('runnerId', runnerId))) {
      if (wanted.has(row.projectId)) continue;
      await ctx.storage.delete(row.storageId);
      await ctx.db.delete(row._id);
    }
    return null;
  },
});

// ------------------------------------------------------------ project icons
// The runner puts each project's picture in file storage (API 5): it asks
// for an upload URL, POSTs the bytes there, then records the storage id
// against the project. projectIcons says what it has already sent, so a
// restart doesn't send every picture again.

export const projectIcons = query({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.array(v.object({ projectId: v.string(), picture: v.string() })),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const row of ctx.db.query('projectIcons').withIndex('by_runner_project', (q) => q.eq('runnerId', runnerId))) {
      out.push({ projectId: row.projectId, picture: row.picture });
    }
    return out;
  },
});

export const iconUploadUrl = mutation({
  args: { key: v.string() },
  returns: v.string(),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    return ctx.storage.generateUploadUrl();
  },
});

export const setProjectIcon = mutation({
  args: { key: v.string(), runnerId: v.string(), projectId: v.string(), picture: v.string(), storageId: v.id('_storage'), mediaType: v.string() },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, projectId, picture, storageId, mediaType }) => {
    checkRunnerKey(key);
    const now = Date.now();
    const existing = await ctx.db
      .query('projectIcons')
      .withIndex('by_runner_project', (q) => q.eq('runnerId', runnerId).eq('projectId', projectId))
      .unique();
    if (existing) {
      if (existing.storageId !== storageId) await ctx.storage.delete(existing.storageId);
      await ctx.db.patch(existing._id, { picture, storageId, mediaType, updatedAt: now });
    } else {
      await ctx.db.insert('projectIcons', { runnerId, projectId, picture, storageId, mediaType, updatedAt: now });
    }
    return null;
  },
});

// The mirror of a runner's own schedules.json. Rows that are schedules in
// their own right (`owned`, API 9) are left alone, and a mirrored row is
// never written over one: a runner still on an older release, a draining
// one say, mustn't undo a move it hasn't heard of.
export const setSchedules = mutation({
  args: { key: v.string(), runnerId: v.string(), schedules: v.array(scheduleDoc) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, schedules }) => {
    checkRunnerKey(key);
    const owned = new Set<string>();
    for await (const row of ctx.db.query('schedules')) {
      if (row.owned) owned.add(row.id);
      else if (row.runnerId === runnerId) await ctx.db.delete(row._id);
    }
    for (const row of schedules) if (!owned.has(row.id)) await ctx.db.insert('schedules', { ...row, runnerId });
    return null;
  },
});

// ------------------------------------------------------------ schedules (API 9)
// Schedules that live here (docs/protocol.md, Schedules, "Runners"). Every
// runner subscribes to the whole list; a schedule's own runner is the only
// one that sends it, and takes each run with claimSchedule first so it's
// sent once even while a handover has two runner processes under one
// runnerId. The runner works out nextRunAt and whenText (it has the cron
// code and the zones); this only stores them.

const CLAIM_MS = 2 * 60_000;

const ownedScheduleDoc = v.object({
  ...scheduleDoc.fields,
  runnerId: v.string(),
  effort: v.optional(v.string()),
  permissionMode: v.optional(v.string()),
  createdBy: v.optional(v.string()),
  runRequestedAt: v.optional(v.string()),
});

const lastRunDoc = v.object({ at: v.string(), outcome: v.string(), threadId: v.optional(v.string()), note: v.optional(v.string()) });

async function scheduleRow(ctx: { db: MutationCtx['db'] }, scheduleId: string) {
  const row = await ctx.db
    .query('schedules')
    .withIndex('by_scheduleId', (q) => q.eq('id', scheduleId))
    .filter((q) => q.eq(q.field('owned'), true))
    .first();
  return row ?? undefined;
}

export const schedules = query({
  args: { key: v.string() },
  returns: v.array(ownedScheduleDoc),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    const out = [];
    for await (const row of ctx.db.query('schedules')) {
      if (!row.owned) continue;
      const { _id, _creationTime, owned, claim, ...rest } = row;
      out.push(rest);
    }
    return out;
  },
});

// Makes or replaces one, as the runner that took schedules.create or
// schedules.update has it. A change to when it runs drops a claim on the
// old time.
export const saveSchedule = mutation({
  args: { key: v.string(), schedule: ownedScheduleDoc },
  returns: v.null(),
  handler: async (ctx, { key, schedule }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, schedule.id);
    if (!row) {
      await ctx.db.insert('schedules', { ...schedule, owned: true });
      return null;
    }
    const claim = row.claim && row.nextRunAt === schedule.nextRunAt ? { claim: row.claim } : {};
    await ctx.db.replace(row._id, { ...schedule, owned: true, ...claim });
    return null;
  },
});

export const deleteSchedule = mutation({
  args: { key: v.string(), scheduleId: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { key, scheduleId }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, scheduleId);
    if (!row) return false;
    await ctx.db.delete(row._id);
    return true;
  },
});

// A runner's schedules.json, the first time it meets API 9: each one it
// has that isn't here yet comes in under its runnerId, and its mirrored
// rows go. Running it twice is harmless.
export const adoptSchedules = mutation({
  args: { key: v.string(), runnerId: v.string(), schedules: v.array(ownedScheduleDoc) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, schedules }) => {
    checkRunnerKey(key);
    for await (const row of ctx.db.query('schedules').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
      if (!row.owned) await ctx.db.delete(row._id);
    }
    for (const s of schedules) {
      if (await scheduleRow(ctx, s.id)) continue;
      await ctx.db.insert('schedules', { ...s, runnerId, owned: true });
    }
    return null;
  },
});

// Takes a run: "due" while the row is still due at that nextRunAt, or
// "request" for the schedules.run waiting at runRequestedAt. No when it's
// another runner's, paused (a due run), or someone else holds it.
export const claimSchedule = mutation({
  args: {
    key: v.string(),
    runnerId: v.string(),
    scheduleId: v.string(),
    holder: v.string(),
    kind: v.union(v.literal('due'), v.literal('request')),
    expect: v.string(),
  },
  returns: v.boolean(),
  handler: async (ctx, { key, runnerId, scheduleId, holder, kind, expect }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, scheduleId);
    if (!row || row.runnerId !== runnerId) return false;
    const now = Date.now();
    if (row.claim && row.claim.until > now && row.claim.holder !== holder) return false;
    if (kind === 'due' && (row.paused || row.nextRunAt !== expect)) return false;
    if (kind === 'request' && row.runRequestedAt !== expect) return false;
    await ctx.db.patch(row._id, { claim: { holder, until: now + CLAIM_MS } });
    return true;
  },
});

// Lets go of a run that couldn't be sent yet (its runner is restarting),
// so the next try, or the next runner process, can take it.
export const releaseSchedule = mutation({
  args: { key: v.string(), scheduleId: v.string(), holder: v.string() },
  returns: v.null(),
  handler: async (ctx, { key, scheduleId, holder }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, scheduleId);
    if (row?.claim?.holder === holder) await ctx.db.patch(row._id, { claim: undefined });
    return null;
  },
});

// Records a run the holder sent (or skipped, or couldn't send). The next
// time goes in only if nobody changed the schedule meanwhile
// (`expectUpdatedAt`): a change already worked out its own.
export const scheduleRan = mutation({
  args: {
    key: v.string(),
    scheduleId: v.string(),
    holder: v.string(),
    lastRun: lastRunDoc,
    sent: v.boolean(),
    expectUpdatedAt: v.string(),
    nextRunAt: v.optional(v.string()),
    finishedAt: v.optional(v.string()),
    request: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { key, scheduleId, holder, lastRun, sent, expectUpdatedAt, nextRunAt, finishedAt, request }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, scheduleId);
    if (!row) return null;
    const patch: Record<string, unknown> = { lastRun, runs: row.runs + (sent ? 1 : 0) };
    if (row.claim?.holder === holder) patch.claim = undefined;
    if (request !== undefined && row.runRequestedAt === request) patch.runRequestedAt = undefined;
    if (row.updatedAt === expectUpdatedAt) {
      patch.nextRunAt = nextRunAt;
      patch.finishedAt = finishedAt;
    }
    await ctx.db.patch(row._id, patch);
    return null;
  },
});

// schedules.run on a runner that isn't the schedule's: its own runner sees
// runRequestedAt and runs it.
export const requestScheduleRun = mutation({
  args: { key: v.string(), scheduleId: v.string(), at: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { key, scheduleId, at }) => {
    checkRunnerKey(key);
    const row = await scheduleRow(ctx, scheduleId);
    if (!row) return false;
    await ctx.db.patch(row._id, { runRequestedAt: at });
    return true;
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

// ------------------------------------------------------------ pocket
// Cards the `pocket` tool files for the phone (schema.ts, pocketCards).

const pocketKey = (title: string) => title.trim().toLowerCase();

export const savePocketCard = mutation({
  args: {
    key: v.string(),
    card: v.object({ title: v.string(), text: v.string(), place: v.optional(v.string()), icon: v.optional(v.string()), threadId: v.optional(v.string()), source: v.optional(v.string()) }),
  },
  returns: v.union(v.literal('added'), v.literal('replaced')),
  handler: async (ctx, { key, card }) => {
    checkRunnerKey(key);
    const k = pocketKey(card.title);
    const had = await ctx.db.query('pocketCards').withIndex('by_key', (q) => q.eq('key', k)).first();
    // A card keeps its look when it's filed again without one.
    const icon = card.icon ?? had?.icon;
    const doc = { ...card, ...(icon ? { icon } : {}), title: card.title.trim(), key: k, updatedAt: new Date().toISOString() };
    if (had) {
      await ctx.db.replace(had._id, doc);
      return 'replaced';
    }
    await ctx.db.insert('pocketCards', doc);
    return 'added';
  },
});

export const removePocketCard = mutation({
  args: { key: v.string(), title: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { key, title }) => {
    checkRunnerKey(key);
    const had = await ctx.db.query('pocketCards').withIndex('by_key', (q) => q.eq('key', pocketKey(title))).first();
    if (had) await ctx.db.delete(had._id);
    return had !== null;
  },
});

export const pocketCards = query({
  args: { key: v.string() },
  returns: v.array(v.object({ title: v.string(), text: v.string(), place: v.optional(v.string()), icon: v.optional(v.string()), threadId: v.optional(v.string()), source: v.optional(v.string()), updatedAt: v.string() })),
  handler: async (ctx, { key }) => {
    checkRunnerKey(key);
    const rows = await ctx.db.query('pocketCards').collect();
    return rows.map((c) => ({ title: c.title, text: c.text, ...(c.place ? { place: c.place } : {}), ...(c.icon ? { icon: c.icon } : {}), ...(c.threadId ? { threadId: c.threadId } : {}), ...(c.source ? { source: c.source } : {}), updatedAt: c.updatedAt }));
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
    // The runner has its copy of the phone's photos by now, and images are
    // meant to live on the Mac. A failed send keeps its photos on the phone,
    // which uploads them again.
    for (const image of Array.isArray(c.args?.images) ? c.args.images : []) {
      if (await ctx.db.system.get(image.storageId)) await ctx.storage.delete(image.storageId);
    }
    return null;
  },
});

// Finished commands older than a day go, and paged marks older than a day
// come off (crons.ts).
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
    // Rows an old phone paged in drop back out of its view after a day; the
    // rows themselves stay, since every message is kept now.
    for await (const m of ctx.db.query('messages').withIndex('by_pagedAt', (q) => q.gt('pagedAt', 0).lt('pagedAt', cutoff))) {
      await ctx.db.patch(m._id, { pagedAt: undefined });
    }
    return null;
  },
});

// ------------------------------------------------------------ thread index (API 12)
// The Mac app's view of other runners' threads (docs/step6-plan.md, part 2).
// A runner writes its own rows when what a sidebar shows changes; a Mac
// app's runner watches the other runners' rows and hands them to the app.

const indexDoc = v.object({
  threadId: v.string(),
  title: v.string(),
  cwd: v.string(),
  accountId: v.string(),
  provider: v.string(),
  model: v.optional(v.string()),
  status: v.string(),
  needsYou: v.boolean(),
  unread: v.boolean(),
  preview: v.string(),
  createdAt: v.string(),
  lastActivityAt: v.string(),
  snoozedUntil: v.optional(v.string()),
  archivedAt: v.optional(v.string()),
  startedBy: v.optional(v.object({ kind: v.string(), label: v.string(), icon: v.optional(v.string()), threadTitle: v.optional(v.string()), why: v.optional(v.string()) })),
});

// Rows made or changed, and threads gone. With `keep`, every row of the
// runner whose thread isn't in it goes too (the first write after start).
export const setThreadIndex = mutation({
  args: { key: v.string(), runnerId: v.string(), rows: v.array(indexDoc), removed: v.array(v.string()), keep: v.optional(v.array(v.string())) },
  returns: v.null(),
  handler: async (ctx, { key, runnerId, rows, removed, keep }) => {
    checkRunnerKey(key);
    for (const row of rows) {
      const existing = await ctx.db
        .query('threadIndex')
        .withIndex('by_runner_thread', (q) => q.eq('runnerId', runnerId).eq('threadId', row.threadId))
        .unique();
      if (existing) await ctx.db.replace(existing._id, { ...row, runnerId });
      else await ctx.db.insert('threadIndex', { ...row, runnerId });
    }
    const gone = new Set(removed);
    const kept = keep ? new Set([...keep, ...rows.map((r) => r.threadId)]) : undefined;
    if (gone.size || kept) {
      for await (const row of ctx.db.query('threadIndex').withIndex('by_runnerId', (q) => q.eq('runnerId', runnerId))) {
        if (gone.has(row.threadId) || (kept && !kept.has(row.threadId))) await ctx.db.delete(row._id);
      }
    }
    return null;
  },
});

// Every runner but this one, with its threads. Each runner's rows are read
// through its own index range, so this one's writes never re-run the query;
// the runners table does, about once a minute per runner (heartbeats), which
// is also what keeps `lastSeenAt` fresh here.
export const otherRunnersThreads = query({
  args: { key: v.string(), runnerId: v.string() },
  returns: v.object({
    runners: v.array(
      v.object({ runnerId: v.string(), name: v.string(), icon: v.optional(v.string()), lastSeenAt: v.number(), rpcUrl: v.optional(v.string()) }),
    ),
    threads: v.array(v.object({ ...indexDoc.fields, runnerId: v.string() })),
  }),
  handler: async (ctx, { key, runnerId }) => {
    checkRunnerKey(key);
    const runners = [];
    const threads = [];
    for await (const r of ctx.db.query('runners')) {
      if (r.runnerId === runnerId) continue;
      runners.push({
        runnerId: r.runnerId,
        name: r.name,
        lastSeenAt: r.lastSeenAt,
        ...(r.icon !== undefined ? { icon: r.icon } : {}),
        ...(r.rpcUrl !== undefined ? { rpcUrl: r.rpcUrl } : {}),
      });
      for await (const t of ctx.db.query('threadIndex').withIndex('by_runnerId', (q) => q.eq('runnerId', r.runnerId))) {
        const { _id, _creationTime, ...rest } = t;
        threads.push(rest);
      }
    }
    return { runners, threads };
  },
});
