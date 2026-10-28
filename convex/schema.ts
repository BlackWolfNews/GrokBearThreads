// The live mirror the phone reads (docs/convex-backend.md, shape A). Every
// row is "the current state of X" as the owning runner last wrote it; the
// runner stays the source of truth and this is never read back by it.
// Only what a phone needs: no transcripts, tool output or images.
import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

// The phone's view of a thread, named as in docs/protocol.md's
// ThreadSummary. Written on change, coalesced, never per token.
export const threadFields = {
  threadId: v.string(),
  runnerId: v.string(),
  title: v.string(),
  cwd: v.string(),
  accountId: v.string(),
  provider: v.string(),
  model: v.optional(v.string()),
  status: v.string(),
  needsYou: v.boolean(),
  unread: v.boolean(), // lastSeq > lastSeenSeq
  preview: v.string(),
  createdAt: v.string(),
  lastActivityAt: v.string(),
  lastActivityMs: v.number(), // lastActivityAt as a number, for the index
  snoozedUntil: v.optional(v.string()),
  snoozedUntilRestart: v.optional(v.boolean()),
  archivedAt: v.optional(v.string()),
  costUsd: v.optional(v.number()),
  projects: v.optional(v.array(v.object({ id: v.string(), title: v.string() }))),
  working: v.optional(v.string()), // the working line: what the CLI is doing in the background
  // The approval or question the thread is waiting on, if any (step 2).
  pendingApproval: v.optional(
    v.union(
      v.object({
        approvalId: v.string(),
        kind: v.literal('approval'),
        name: v.string(),
        title: v.string(),
        options: v.array(v.string()),
        inputSummary: v.optional(v.string()),
      }),
      v.object({
        approvalId: v.string(),
        kind: v.literal('question'),
        questions: v.array(
          v.object({
            question: v.string(),
            header: v.optional(v.string()),
            multiSelect: v.boolean(),
            options: v.array(v.object({ label: v.string(), description: v.optional(v.string()) })),
          }),
        ),
      }),
    ),
  ),
};

// Which list a thread is in on the phone, worked out by the runner so the
// phone and the Mac app agree: "inbox", "hibernating" (snoozed) or "den"
// (archived).
export const views = ['inbox', 'hibernating', 'den'] as const;

export default defineSchema({
  // One row per runner (the Mac, Tinker Desk later), written every minute.
  // A phone treats one not seen for 3 minutes as offline.
  runners: defineTable({
    runnerId: v.string(),
    name: v.string(),
    version: v.string(),
    release: v.optional(v.string()),
    lastSeenAt: v.number(),
    startedAt: v.string(),
    draining: v.boolean(),
    threadCount: v.number(),
  }).index('by_runnerId', ['runnerId']),

  threads: defineTable({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))) })
    .index('by_threadId', ['threadId'])
    .index('by_runnerId', ['runnerId'])
    .index('by_view_activity', ['view', 'lastActivityMs']),

  // The last 20 text messages of each thread (step 2), plus pages the
  // phone asked for, which a cron deletes a day later.
  messages: defineTable({
    threadId: v.string(),
    seq: v.number(),
    role: v.union(v.literal('user'), v.literal('assistant')),
    text: v.string(),
    origin: v.optional(v.string()),
    at: v.string(),
    pagedAt: v.optional(v.number()),
  }).index('by_thread_seq', ['threadId', 'seq']),

  // What the phone asks a runner to do (step 3). The owning runner takes
  // pending ones for its runnerId (or "any"), applies them through the
  // same code the Mac app uses, and marks them done or failed.
  commands: defineTable({
    runnerId: v.string(), // or "any"
    threadId: v.optional(v.string()),
    kind: v.union(v.literal('send'), v.literal('respond'), v.literal('update'), v.literal('create')),
    args: v.any(),
    state: v.union(v.literal('pending'), v.literal('taken'), v.literal('done'), v.literal('failed')),
    note: v.optional(v.string()),
    createdAt: v.number(),
    takenAt: v.optional(v.number()),
    doneAt: v.optional(v.number()),
    resultThreadId: v.optional(v.string()), // for create, once it lands
  })
    .index('by_runner_state', ['runnerId', 'state'])
    .index('by_state', ['state']),

  // Phone tokens: only the hash is kept. Issued with
  // `npx convex run tokens:issue '{"name":"iphone","days":90}'`.
  tokens: defineTable({
    hash: v.string(),
    name: v.string(),
    createdAt: v.number(),
    expiresAt: v.number(),
    revokedAt: v.optional(v.number()),
  }).index('by_hash', ['hash']),

  // The runner's projects, schedules and accounts (docs/protocol.md), one
  // row each, replaced as a whole when the runner's list changes.
  projects: defineTable({
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
  }).index('by_runnerId', ['runnerId']),

  schedules: defineTable({
    runnerId: v.string(),
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
  }).index('by_runnerId', ['runnerId']),

  accounts: defineTable({
    runnerId: v.string(),
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
  }).index('by_runnerId', ['runnerId']),

  // APNs tokens for push (step 4), one row per phone install.
  devices: defineTable({
    apnsToken: v.string(),
    environment: v.union(v.literal('sandbox'), v.literal('production')),
    tokenName: v.string(),
    updatedAt: v.number(),
  }).index('by_apnsToken', ['apnsToken']),
});
