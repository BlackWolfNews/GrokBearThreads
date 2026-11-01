// A shared thread on the website (docs/website.md, "Sharing"): /s/<slug>,
// read-only and live. share:view is the only function that takes no phone
// token. Anyone may ask; it answers only while the thread's `share` (as
// the runner mirrored it) is "link".
//
// Readers get the thread's title, its messages, one line per tool call and
// the pictures the runner uploaded for it (sync:addShareImage), and
// nothing else: no folder, account, model, cost, approvals or composer.
//
// Mike's own phone or browser token also reads it while it isn't shared,
// and gets `manage` so the page can offer Stop sharing and Share again
// (phone:share, a command the runner applies).
import { v } from 'convex/values';
import { query, type QueryCtx } from './_generated/server';
import type { Doc } from './_generated/dataModel';
import { checkPhoneToken } from './lib';

const PAGE_DEFAULT = 80;
const PAGE_MAX = 2000;

const message = v.object({
  seq: v.number(),
  role: v.union(v.literal('user'), v.literal('assistant'), v.literal('tool')),
  text: v.string(),
  toolKind: v.optional(v.string()),
  at: v.string(),
});

// A picture in a shared thread. `src` is set for one the agent put in its
// text as Markdown, which the page swaps for `url`; without it the picture
// goes after the row with the greatest seq at or before its own (an
// attachment on Mike's message, or what a tool handed back).
export const shareImage = v.object({
  seq: v.number(),
  src: v.optional(v.string()),
  url: v.string(),
  width: v.optional(v.number()),
  height: v.optional(v.number()),
});

async function threadBySlug(ctx: QueryCtx, slug: string): Promise<Doc<'threads'> | null> {
  if (!slug || slug.length > 100) return null;
  return ctx.db
    .query('threads')
    .withIndex('by_share_slug', (q) => q.eq('share.slug', slug))
    .first();
}

async function isMike(ctx: QueryCtx, token?: string): Promise<boolean> {
  if (!token) return false;
  try {
    await checkPhoneToken(ctx, token);
    return true;
  } catch {
    return false;
  }
}

// A thread's uploaded pictures from seq `from` on, with their URLs.
export async function imagesFrom(ctx: QueryCtx, threadId: string, from: number) {
  const out: { seq: number; src?: string; url: string; width?: number; height?: number }[] = [];
  for await (const img of ctx.db.query('shareImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId).gte('seq', from))) {
    const url = await ctx.storage.getUrl(img.storageId);
    if (!url) continue;
    out.push({ seq: img.seq, ...(img.src ? { src: img.src } : {}), url, ...(img.width ? { width: img.width } : {}), ...(img.height ? { height: img.height } : {}) });
  }
  return out;
}

// A thread's pictures for Mike's own phone (replyImages, API 24), never for
// share:view: a shared page gets only what was uploaded for it. A file both
// pinned and shown in a reply goes once, in the reply, and one pinned twice
// goes at the first pin.
export const phoneImage = v.object({
  seq: v.number(),
  src: v.optional(v.string()),
  pinned: v.optional(v.boolean()),
  url: v.string(),
  width: v.optional(v.number()),
  height: v.optional(v.number()),
});

export async function replyImagesFrom(ctx: QueryCtx, threadId: string, from: number) {
  const rows = await ctx.db.query('replyImages').withIndex('by_thread_seq', (q) => q.eq('threadId', threadId).gte('seq', from)).collect();
  const inReplies = new Set(rows.filter((r) => r.src).map((r) => r.path));
  const out: { seq: number; src?: string; pinned?: boolean; url: string; width?: number; height?: number }[] = [];
  for (const img of rows) {
    if (img.pinned) {
      if (inReplies.has(img.path)) continue;
      inReplies.add(img.path);
    }
    const url = await ctx.storage.getUrl(img.storageId);
    if (!url) continue;
    out.push({ seq: img.seq, ...(img.src ? { src: img.src } : {}), ...(img.pinned ? { pinned: true } : {}), url, ...(img.width ? { width: img.width } : {}), ...(img.height ? { height: img.height } : {}) });
  }
  return out;
}

export const view = query({
  args: { slug: v.string(), token: v.optional(v.string()), limit: v.optional(v.number()) },
  returns: v.union(
    v.object({ state: v.literal('gone') }),
    v.object({
      state: v.literal('ok'),
      title: v.string(),
      running: v.boolean(),
      working: v.optional(v.string()),
      lastActivityAt: v.string(),
      messages: v.array(message),
      images: v.array(shareImage),
      hasMore: v.boolean(),
      // Only for Mike: whether it's shared now, for the page's controls.
      manage: v.optional(v.object({ threadId: v.string(), shared: v.boolean() })),
    }),
  ),
  handler: async (ctx, { slug, token, limit }) => {
    const t = await threadBySlug(ctx, slug);
    if (!t?.share) return { state: 'gone' as const };
    const shared = t.share.access === 'link';
    const mike = await isMike(ctx, token);
    if (!shared && !mike) return { state: 'gone' as const };
    const want = Math.max(1, Math.min(PAGE_MAX, Math.floor(limit ?? PAGE_DEFAULT)));
    const out: { seq: number; role: 'user' | 'assistant' | 'tool'; text: string; toolKind?: string; at: string }[] = [];
    let hasMore = false;
    for await (const m of ctx.db.query('messages').withIndex('by_thread_seq', (q) => q.eq('threadId', t.threadId)).order('desc')) {
      if (out.length >= want) {
        hasMore = true;
        break;
      }
      out.push({ seq: m.seq, role: m.role, text: m.text, ...(m.toolKind ? { toolKind: m.toolKind } : {}), at: m.at });
    }
    out.reverse();
    return {
      state: 'ok' as const,
      title: t.title,
      running: t.status === 'running' || t.status === 'starting',
      ...(t.working ? { working: t.working } : {}),
      lastActivityAt: t.lastActivityAt,
      messages: out,
      images: await imagesFrom(ctx, t.threadId, hasMore ? (out[0]?.seq ?? 0) : 0),
      hasMore,
      ...(mike ? { manage: { threadId: t.threadId, shared } } : {}),
    };
  },
});
