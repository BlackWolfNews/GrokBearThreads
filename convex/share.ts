// A shared thread on the website (API 7; docs/website.md, "Sharing"). The
// only functions here that take no phone token: anyone may ask, and what
// they get depends on the thread's `share` as the runner mirrored it.
//
// - "link": anyone with /s/<slug> reads the thread.
// - "people": only the listed email addresses. A reader asks for a code
//   (sendCode), which goes to that address through Resend, and swaps it
//   for a viewer token (verifyCode) the browser keeps for that link.
//
// Readers get the thread's title, its messages and one line per tool call,
// as the phone does, and nothing else: no folder, account, model, cost,
// approvals or composer. Mike's own phone token reads it whatever the
// access, so he can open his own link.
import { ConvexError, v } from 'convex/values';
import { internalAction, internalMutation, mutation, query, type MutationCtx, type QueryCtx } from './_generated/server';
import { internal } from './_generated/api';
import type { Doc } from './_generated/dataModel';
import { checkPhoneToken, sha256 } from './lib';

const CODE_MS = 10 * 60_000;
const CODE_TRIES = 5;
// Codes one address can be sent for one link in an hour, so the page
// can't be used to fill someone's inbox.
const CODES_PER_HOUR = 5;
const VIEWER_DAYS = 30;
const PAGE_DEFAULT = 80;
const PAGE_MAX = 2000;

const message = v.object({
  seq: v.number(),
  role: v.union(v.literal('user'), v.literal('assistant'), v.literal('tool')),
  text: v.string(),
  toolKind: v.optional(v.string()),
  at: v.string(),
});

export function normalEmail(email: string): string {
  return email.trim().toLowerCase();
}

function looksLikeEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && email.length <= 254;
}

async function sharedThread(ctx: QueryCtx | MutationCtx, slug: string): Promise<Doc<'threads'> | null> {
  if (!slug || slug.length > 100) return null;
  const t = await ctx.db
    .query('threads')
    .withIndex('by_share_slug', (q) => q.eq('share.slug', slug))
    .first();
  return t?.share ? t : null;
}

// Who is reading a "people" thread: "mike" (a live phone or browser
// token), the address of a viewer token for this link that is still on
// the list, or undefined (they have to sign in).
async function reader(ctx: QueryCtx, t: Doc<'threads'>, viewer?: string, token?: string): Promise<'mike' | { email: string } | undefined> {
  if (token) {
    try {
      await checkPhoneToken(ctx, token);
      return 'mike';
    } catch {
      // Not Mike, or an expired token: carry on as a reader.
    }
  }
  if (!viewer) return undefined;
  const hash = await sha256(viewer);
  const row = await ctx.db
    .query('shareViewers')
    .withIndex('by_hash', (q) => q.eq('hash', hash))
    .unique();
  if (!row || row.slug !== t.share?.slug || row.expiresAt < Date.now()) return undefined;
  return (t.share.people ?? []).includes(row.email) ? { email: row.email } : undefined;
}

export const view = query({
  args: { slug: v.string(), viewer: v.optional(v.string()), token: v.optional(v.string()), limit: v.optional(v.number()) },
  returns: v.union(
    v.object({ state: v.literal('gone') }),
    v.object({ state: v.literal('signIn'), title: v.string() }),
    v.object({
      state: v.literal('ok'),
      title: v.string(),
      running: v.boolean(),
      working: v.optional(v.string()),
      lastActivityAt: v.string(),
      messages: v.array(message),
      hasMore: v.boolean(),
      email: v.optional(v.string()),
    }),
  ),
  handler: async (ctx, { slug, viewer, token, limit }) => {
    const t = await sharedThread(ctx, slug);
    if (!t) return { state: 'gone' as const };
    let email: string | undefined;
    if (t.share?.access === 'people') {
      const who = await reader(ctx, t, viewer, token);
      if (!who) return { state: 'signIn' as const, title: t.title };
      if (who !== 'mike') email = who.email;
    }
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
    return {
      state: 'ok' as const,
      title: t.title,
      running: t.status === 'running' || t.status === 'starting',
      ...(t.working ? { working: t.working } : {}),
      lastActivityAt: t.lastActivityAt,
      messages: out.reverse(),
      hasMore,
      ...(email ? { email } : {}),
    };
  },
});

// Sends a sign-in code to an address on a "people" thread's list. The
// answer is the same whether or not the address is on it, so the page
// can't be used to find out who a thread is shared with.
export const sendCode = mutation({
  args: { slug: v.string(), email: v.string() },
  returns: v.object({ ok: v.boolean(), message: v.optional(v.string()) }),
  handler: async (ctx, args) => {
    const email = normalEmail(args.email);
    if (!looksLikeEmail(email)) return { ok: false, message: 'That doesn’t look like an email address.' };
    const t = await sharedThread(ctx, args.slug);
    if (!t || t.share?.access !== 'people') return { ok: false, message: 'This link no longer works.' };
    if (!process.env.RESEND_API_KEY) return { ok: false, message: 'Email isn’t set up for this Threadbear yet, so no code can be sent.' };
    if (!(t.share.people ?? []).includes(email)) return { ok: true };
    const now = Date.now();
    const recent = await ctx.db
      .query('shareCodes')
      .withIndex('by_slug_email', (q) => q.eq('slug', args.slug).eq('email', email))
      .filter((q) => q.gt(q.field('createdAt'), now - 60 * 60_000))
      .collect();
    if (recent.length >= CODES_PER_HOUR) return { ok: false, message: 'Too many codes for that address. Try again in an hour.' };
    const digits = new Uint32Array(1);
    crypto.getRandomValues(digits);
    const code = String(digits[0]! % 1_000_000).padStart(6, '0');
    await ctx.db.insert('shareCodes', { slug: args.slug, email, hash: await sha256(`${args.slug}:${email}:${code}`), createdAt: now, expiresAt: now + CODE_MS, attempts: 0 });
    await ctx.scheduler.runAfter(0, internal.share.email, { to: email, code, title: t.title });
    return { ok: true };
  },
});

// Swaps a code for a viewer token, which the browser keeps for this link.
export const verifyCode = mutation({
  args: { slug: v.string(), email: v.string(), code: v.string() },
  returns: v.union(v.object({ ok: v.literal(true), viewer: v.string() }), v.object({ ok: v.literal(false), message: v.string() })),
  handler: async (ctx, args) => {
    const email = normalEmail(args.email);
    const code = args.code.replace(/\D/g, '');
    const t = await sharedThread(ctx, args.slug);
    if (!t || t.share?.access !== 'people') return { ok: false as const, message: 'This link no longer works.' };
    const now = Date.now();
    const live = (
      await ctx.db
        .query('shareCodes')
        .withIndex('by_slug_email', (q) => q.eq('slug', args.slug).eq('email', email))
        .collect()
    ).filter((c) => c.expiresAt > now && c.attempts < CODE_TRIES);
    const hash = await sha256(`${args.slug}:${email}:${code}`);
    const match = live.find((c) => c.hash === hash);
    if (!match || !(t.share.people ?? []).includes(email)) {
      for (const c of live) await ctx.db.patch(c._id, { attempts: c.attempts + 1 });
      return { ok: false as const, message: live.length ? 'That code isn’t right.' : 'That code has expired. Send a new one.' };
    }
    for (const c of live) await ctx.db.delete(c._id);
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const viewer = 'tbv_' + Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    await ctx.db.insert('shareViewers', { slug: args.slug, email, hash: await sha256(viewer), createdAt: now, expiresAt: now + VIEWER_DAYS * 24 * 60 * 60_000 });
    return { ok: true as const, viewer };
  },
});

// Sends the code through Resend's API. RESEND_API_KEY is the deployment's
// (`npx convex env set RESEND_API_KEY … --prod`); SHARE_EMAIL_FROM can
// change the sender, a verified domain in that Resend account.
export const email = internalAction({
  args: { to: v.string(), code: v.string(), title: v.string() },
  returns: v.null(),
  handler: async (_ctx, { to, code, title }) => {
    const key = process.env.RESEND_API_KEY;
    if (!key) throw new ConvexError({ kind: 'config', message: 'RESEND_API_KEY is not set' });
    const from = process.env.SHARE_EMAIL_FROM ?? 'Threadbear <threadbear@mail.mikecann.app>';
    const text = `Your code to read “${title}” on Threadbear is ${code}.\n\nIt works for 10 minutes. If you didn’t ask for it, you can ignore this email.`;
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject: `${code} is your Threadbear code`, text }),
    });
    if (!res.ok) throw new Error(`Resend said ${res.status}: ${(await res.text()).slice(0, 300)}`);
    return null;
  },
});

// Codes and viewer sign-ins past their time (crons.ts).
export const pruneExpired = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const now = Date.now();
    for (const table of ['shareCodes', 'shareViewers'] as const) {
      for await (const row of ctx.db.query(table).withIndex('by_expiresAt', (q) => q.lt('expiresAt', now))) await ctx.db.delete(row._id);
    }
    return null;
  },
});
