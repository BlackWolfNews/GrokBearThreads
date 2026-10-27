// Phone tokens. Issued from a terminal, so only someone logged in to the
// Convex team can make one:
//   npx convex run tokens:issue '{"name":"iphone","days":90}'          (dev)
//   npx convex run tokens:issue '{"name":"iphone","days":90}' --prod   (prod)
// The plain token is printed once and never stored. Get it onto the phone
// the way Quick Ask does (a one-off LAN page and a QR code), not the
// clipboard.
import { v } from 'convex/values';
import { internalMutation } from './_generated/server';
import { sha256 } from './lib';

export const issue = internalMutation({
  args: { name: v.string(), days: v.optional(v.number()) },
  returns: v.object({ token: v.string(), expiresAt: v.string() }),
  handler: async (ctx, { name, days }) => {
    const bytes = new Uint8Array(24);
    crypto.getRandomValues(bytes);
    const token = 'tb_' + Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    const now = Date.now();
    const expiresAt = now + Math.max(1, days ?? 90) * 24 * 60 * 60_000;
    await ctx.db.insert('tokens', { hash: await sha256(token), name, createdAt: now, expiresAt });
    return { token, expiresAt: new Date(expiresAt).toISOString() };
  },
});

// Revokes every token with the name (a lost phone).
export const revoke = internalMutation({
  args: { name: v.string() },
  returns: v.number(),
  handler: async (ctx, { name }) => {
    let n = 0;
    for await (const row of ctx.db.query('tokens')) {
      if (row.name === name && !row.revokedAt) {
        await ctx.db.patch(row._id, { revokedAt: Date.now() });
        n++;
      }
    }
    return n;
  },
});

export const list = internalMutation({
  args: {},
  returns: v.array(v.object({ name: v.string(), createdAt: v.string(), expiresAt: v.string(), revoked: v.boolean() })),
  handler: async (ctx) => {
    const out = [];
    for await (const row of ctx.db.query('tokens')) {
      out.push({ name: row.name, createdAt: new Date(row.createdAt).toISOString(), expiresAt: new Date(row.expiresAt).toISOString(), revoked: Boolean(row.revokedAt) });
    }
    return out;
  },
});
