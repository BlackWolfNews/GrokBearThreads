// The relay keeps as little as it can: one row per Threadbear install (an
// id, the hash of its key, when it was made and last seen, the app version
// it says it is) and a count of notifications per day. Never a name, a
// thread, a message or a device token. docs/push-relay.md.
import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

export default defineSchema({
  installs: defineTable({
    installId: v.string(),
    keyHash: v.string(),
    createdAt: v.number(),
    lastSeenAt: v.number(),
    version: v.optional(v.string()),
    // Sends in the current hour, for the rate limit.
    hourStart: v.number(),
    hourSends: v.number(),
  }).index('by_installId', ['installId']),

  // Anonymous totals per UTC day: notifications forwarded and installs that
  // sent one. What Mike looks at; nothing per install.
  days: defineTable({
    day: v.string(),
    sends: v.number(),
    failed: v.number(),
    registrations: v.number(),
  }).index('by_day', ['day']),
});
