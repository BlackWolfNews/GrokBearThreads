// The phone's API (ios/, thread f5247e5b). Every function takes the phone
// token and throws ConvexError({ kind: "auth" }) for a bad or expired one.
// Queries read the mirror; mutations only ever add a row to `commands`,
// which the owning runner applies (step 3 of docs/convex-backend.md) and
// marks done or failed. Nothing here touches a runner directly.
import { ConvexError, v, type Infer } from 'convex/values';
import { mutation, query, type QueryCtx } from './_generated/server';
import type { Doc } from './_generated/dataModel';
import { threadFields, views } from './schema';
import { checkPhoneToken } from './lib';
import { API_VERSION } from './version';
import { imagesFrom, shareImage } from './share';

// A runner not heard from for this long is offline, and a command with no
// runnerId goes to the newest one still online.
const ONLINE_MS = 3 * 60_000;
const DEN_LIMIT = 100;

const row = v.object({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) });
const message = v.object({ seq: v.number(), role: v.union(v.literal('user'), v.literal('assistant')), text: v.string(), origin: v.optional(v.string()), at: v.string() });
const pageMessage = v.object({ seq: v.number(), role: v.union(v.literal('user'), v.literal('assistant'), v.literal('tool')), text: v.string(), origin: v.optional(v.string()), toolKind: v.optional(v.string()), summary: v.optional(v.boolean()), at: v.string() });
// phone:thread's newest text messages for an old phone, and how far back it
// looks past tool rows for them.
const MESSAGES_SHOWN = 20;
const THREAD_SCAN = 400;
// phone:messages page sizes.
const PAGE_DEFAULT = 50;
// The website asks for more as you scroll back by raising limit, so one
// live query covers everything it shows.
const PAGE_MAX = 2000;

function strip<T extends { _id: unknown; _creationTime: unknown }>(doc: T): Omit<T, '_id' | '_creationTime'> {
  const { _id, _creationTime, ...rest } = doc;
  return rest;
}

// A thread row as the phone sees it: only the fields `row` lists. The
// mirror keeps fields of its own on the row (pushedAt and pushHeldAt from
// push.ts, and whatever comes next), and returning one fails the query's
// validator, which broke every phone's inbox twice: once for pushedAt on
// 27 Oct, once for pushHeldAt on 29 Oct (a push held back while Mike was
// at the Mac). So the row is picked by the validator's own keys, not
// stripped of the ones known today.
const PHONE_THREAD_KEYS = new Set([...Object.keys(threadFields), 'view']);
type PhoneThread = Infer<typeof row>;
function stripThread(doc: Doc<'threads'>): PhoneThread {
  const out: Record<string, unknown> = {};
  for (const [k, value] of Object.entries(doc)) if (PHONE_THREAD_KEYS.has(k) && value !== undefined) out[k] = value;
  return out as PhoneThread;
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

// The thread's row and, as API 1 had it, its newest MESSAGES_SHOWN text
// messages plus any an old phone paged in. Tool rows are never in it: an app
// built before API 2 can't decode them. Newer clients use phone:messages.
export const thread = query({
  args: { token: v.string(), threadId: v.string() },
  returns: v.object({ thread: row, messages: v.array(message) }),
  handler: async (ctx, { token, threadId }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    const bySeq = new Map<number, { seq: number; role: 'user' | 'assistant'; text: string; origin?: string; at: string }>();
    const add = (m: Doc<'messages'>) => {
      if (m.role === 'tool') return;
      bySeq.set(m.seq, { seq: m.seq, role: m.role, text: m.text, ...(m.origin ? { origin: m.origin } : {}), at: m.at });
    };
    // Tool rows sit between the text ones, so this reads back far enough to
    // find the newest text messages without reading the whole thread.
    let text = 0;
    let read = 0;
    for await (const m of ctx.db.query('messages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId)).order('desc')) {
      if (++read > THREAD_SCAN) break;
      if (m.role === 'tool') continue;
      add(m);
      if (++text >= MESSAGES_SHOWN) break;
    }
    for await (const m of ctx.db.query('messages').withIndex('by_thread_pagedAt', (q) => q.eq('threadId', threadId).gt('pagedAt', 0))) add(m);
    const messages = [...bySeq.values()].sort((a, b) => a.seq - b.seq);
    return { thread: stripThread(t), messages };
  },
});

// A page of a thread's messages, newest first in the reading but returned
// oldest first: the newest `limit` with no beforeSeq (live, so new messages
// arrive by themselves), or the `limit` before beforeSeq. Tool rows (one line
// each) only with tools: true. hasMore says whether there are older ones.
// Since API 2; reads Convex alone, so it works while the Mac is asleep.
export const messages = query({
  args: { token: v.string(), threadId: v.string(), beforeSeq: v.optional(v.number()), limit: v.optional(v.number()), tools: v.optional(v.boolean()) },
  // images (API 8): a shared thread's uploaded pictures from the page's
  // first row on (share.ts), so Mike's page shows what the shared one does.
  returns: v.object({ messages: v.array(pageMessage), hasMore: v.boolean(), images: v.optional(v.array(shareImage)) }),
  handler: async (ctx, { token, threadId, beforeSeq, limit, tools }) => {
    await checkPhoneToken(ctx, token);
    const want = Math.max(1, Math.min(PAGE_MAX, Math.floor(limit ?? PAGE_DEFAULT)));
    const out: { seq: number; role: 'user' | 'assistant' | 'tool'; text: string; origin?: string; toolKind?: string; summary?: boolean; at: string }[] = [];
    let hasMore = false;
    const q = ctx.db
      .query('messages')
      .withIndex('by_thread_seq', (x) => (beforeSeq === undefined ? x.eq('threadId', threadId) : x.eq('threadId', threadId).lt('seq', beforeSeq)))
      .order('desc');
    for await (const m of q) {
      if (m.role === 'tool' && !tools) continue;
      if (out.length >= want) {
        hasMore = true;
        break;
      }
      out.push({ seq: m.seq, role: m.role, text: m.text, ...(m.origin ? { origin: m.origin } : {}), ...(m.toolKind ? { toolKind: m.toolKind } : {}), ...(m.summary ? { summary: true } : {}), at: m.at });
    }
    out.reverse();
    const images = tools && out.length ? await imagesFrom(ctx, threadId, hasMore || beforeSeq !== undefined ? out[0]!.seq : 0) : [];
    return { messages: out, hasMore, ...(images.length ? { images } : {}) };
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

// A project as the phone shows it. `icon` (API 5) is the Mac's ProjectIcon
// with the picture as a URL into file storage (sync.ts, project icons)
// instead of a path on the Mac; absent from a runner before API 5.
const projectRow = v.object({
  runnerId: v.string(),
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
  icon: v.optional(v.object({ symbol: v.optional(v.string()), url: v.optional(v.string()), by: v.string() })),
});

export const projects = query({
  args: { token: v.string(), archived: v.optional(v.boolean()) },
  returns: v.array(projectRow),
  handler: async (ctx, { token, archived }) => {
    await checkPhoneToken(ctx, token);
    const out = [];
    for await (const p of ctx.db.query('projects')) {
      if (p.archived && !archived) continue;
      const { icon, ...rest } = strip(p);
      if (!icon) {
        out.push(rest);
        continue;
      }
      let url: string | undefined;
      if (icon.picture) {
        const stored = await ctx.db
          .query('projectIcons')
          .withIndex('by_runner_project', (q) => q.eq('runnerId', p.runnerId).eq('projectId', p.id))
          .unique();
        url = (stored && (await ctx.storage.getUrl(stored.storageId))) ?? undefined;
      }
      out.push({ ...rest, icon: { ...(icon.symbol ? { symbol: icon.symbol } : {}), ...(url ? { url } : {}), by: icon.by } });
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
    // `owned` and `claim` are the backend's own (API 9), not the phone's.
    for await (const s of ctx.db.query('schedules')) {
      const { owned, claim, ...rest } = strip(s);
      out.push(rest);
    }
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

// answers (API 14): the open card's asks the message answers, as the Mac
// app passes them to threads.send, so the transcript shows them as answers.
export const send = mutation({
  args: { token: v.string(), threadId: v.string(), text: v.string(), answers: v.optional(v.array(v.object({ action: v.string(), answer: v.string() }))) },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, text, answers }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'send', threadId, { text, ...(answers?.length ? { answers } : {}) });
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

// Shares the thread by link, stops sharing it, or gives it a new link
// (API 8; docs/website.md, "Sharing"), from the website. The runner
// applies it as the Mac app's share button does.
export const share = mutation({
  args: { token: v.string(), threadId: v.string(), access: v.union(v.literal('off'), v.literal('link')), newLink: v.optional(v.boolean()) },
  returns: v.id('commands'),
  handler: async (ctx, { token, threadId, access, newLink }) => {
    await checkPhoneToken(ctx, token);
    const t = await findThread(ctx, threadId);
    return queue(ctx, t.runnerId, 'share', threadId, { access, ...(newLink ? { newLink: true } : {}) });
  },
});

// A new thread. With no runnerId, the newest runner still online takes it
// (or the first one back, as "any").
export const create = mutation({
  args: { token: v.string(), text: v.string(), runnerId: v.optional(v.string()), cwd: v.optional(v.string()), accountId: v.optional(v.string()), model: v.optional(v.string()) },
  returns: v.id('commands'),
  handler: async (ctx, { token, text, runnerId, cwd, accountId, model }) => {
    await checkPhoneToken(ctx, token);
    const target = runnerId || (await newestRunner(ctx));
    return queue(ctx, target, 'create', undefined, { text, ...(cwd ? { cwd } : {}), ...(accountId ? { accountId } : {}), ...(model ? { model } : {}) });
  },
});

// A quick ask the phone has already answered out loud (API 10), kept as a
// thread so Mike can carry on in it. The runner writes the exchange with
// no turn run (docs/protocol.md, Sync, "quickAsk"); phone:command gives the
// new thread's id once it's done. Targets a runner as create does.
export const quickAsk = mutation({
  args: {
    token: v.string(),
    question: v.string(),
    answer: v.string(),
    sources: v.optional(v.array(v.object({ title: v.string(), url: v.string() }))),
    askedAt: v.number(),
    runnerId: v.optional(v.string()),
  },
  returns: v.id('commands'),
  handler: async (ctx, { token, question, answer, sources, askedAt, runnerId }) => {
    await checkPhoneToken(ctx, token);
    const q = question.trim();
    const a = answer.trim();
    if (!q || q.length > 2000) throw new ConvexError({ kind: 'invalid', message: 'question must be 1 to 2000 characters' });
    if (!a || a.length > 20000) throw new ConvexError({ kind: 'invalid', message: 'answer must be 1 to 20000 characters' });
    if ((sources?.length ?? 0) > 10) throw new ConvexError({ kind: 'invalid', message: 'at most 10 sources' });
    if (!Number.isFinite(askedAt)) throw new ConvexError({ kind: 'invalid', message: 'askedAt must be a time' });
    const target = runnerId || (await newestRunner(ctx));
    return queue(ctx, target, 'quickAsk', undefined, { question: q, answer: a, sources: sources ?? [], askedAt });
  },
});

// The newest runner seen in the last ONLINE_MS, or "any" (the first one
// back takes it).
async function newestRunner(ctx: QueryCtx): Promise<string> {
  let best: { runnerId: string; lastSeenAt: number } | undefined;
  for await (const r of ctx.db.query('runners')) {
    if (r.draining || Date.now() - r.lastSeenAt > ONLINE_MS) continue;
    if (!best || r.lastSeenAt > best.lastSeenAt) best = r;
  }
  return best?.runnerId ?? 'any';
}

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
  // pushKey (API 4): the phone's own key for what goes through the push
  // relay, base64 of 32 bytes. Kept from an earlier registration if left out.
  args: { token: v.string(), apnsToken: v.string(), environment: v.union(v.literal('sandbox'), v.literal('production')), pushKey: v.optional(v.string()) },
  returns: v.null(),
  handler: async (ctx, { token, apnsToken, environment, pushKey }) => {
    if (pushKey !== undefined && !/^[A-Za-z0-9+/]{43}=$/.test(pushKey)) throw new ConvexError({ kind: 'invalid', message: 'pushKey must be base64 of 32 bytes' });
    const t = await checkPhoneToken(ctx, token);
    const existing = await ctx.db
      .query('devices')
      .withIndex('by_apnsToken', (q) => q.eq('apnsToken', apnsToken))
      .unique();
    const key = pushKey ?? existing?.pushKey;
    const row = { apnsToken, environment, tokenName: t.name, updatedAt: Date.now(), ...(existing?.notify ? { notify: existing.notify } : {}), ...(key ? { pushKey: key } : {}) };
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert('devices', row);
    return null;
  },
});

// When this phone wants a push (API 3): "away" (the default) only while
// Mike isn't at the Mac, "always", or "off".
export const setNotifications = mutation({
  args: { token: v.string(), apnsToken: v.string(), notify: v.union(v.literal('away'), v.literal('always'), v.literal('off')) },
  returns: v.null(),
  handler: async (ctx, { token, apnsToken, notify }) => {
    await checkPhoneToken(ctx, token);
    const row = await ctx.db
      .query('devices')
      .withIndex('by_apnsToken', (q) => q.eq('apnsToken', apnsToken))
      .unique();
    if (!row) throw new ConvexError({ kind: 'notFound', message: 'this phone has not registered for notifications' });
    await ctx.db.patch(row._id, { notify });
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

async function queue(ctx: { db: QueryCtx['db'] & { insert: any } }, runnerId: string, kind: 'send' | 'respond' | 'update' | 'create' | 'page' | 'share' | 'quickAsk', threadId: string | undefined, args: Record<string, unknown>) {
  return ctx.db.insert('commands', { runnerId, ...(threadId ? { threadId } : {}), kind, args, state: 'pending', createdAt: Date.now() });
}
