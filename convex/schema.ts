// The live mirror the phone reads (docs/convex-backend.md, shape A). Every
// row is "the current state of X" as the owning runner last wrote it; the
// runner stays the source of truth and this is never read back by it.
// Only what a phone needs: no transcripts or tool output, and the only images
// are what an agent showed Mike on purpose (replyImages) or a shared thread's.
import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

// A thread's sharing, as the runner mirrors it (ThreadShare in
// docs/protocol.md): "link" is readable by anyone with /s/<slug>; "off"
// (since API 8) only by Mike, so his page can offer Share again. A thread
// never shared has none. "people" and `people` came from API 7 runners
// (sharing with specific people, dropped 29 Oct) and read as off.
export const shareField = v.object({
  access: v.union(v.literal('off'), v.literal('link'), v.literal('people')),
  slug: v.string(),
  people: v.optional(v.array(v.string())),
});

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
  // Back from hibernating by itself and not opened yet: the row says
  // "Woke up" (docs/protocol.md, ThreadSummary.woke).
  woke: v.optional(v.object({ at: v.string(), since: v.optional(v.string()) })),
  // Who started it, when that wasn't Mike: the row's byline
  // (docs/protocol.md, "Who started a thread"). Since API 22.
  startedBy: v.optional(v.object({ kind: v.string(), label: v.string(), icon: v.optional(v.string()), why: v.optional(v.string()) })),
  archivedAt: v.optional(v.string()),
  costUsd: v.optional(v.number()),
  projects: v.optional(v.array(v.object({ id: v.string(), title: v.string() }))),
  working: v.optional(v.string()), // the working line: what the CLI is doing in the background
  earliestSeq: v.optional(v.number()), // seq of the thread's first text message, for "Load earlier messages"
  // Whether anyone with the /s/<slug> link can read it (docs/website.md,
  // "Sharing"). Absent: never shared.
  share: v.optional(shareField),
  // The open card of asks from the agent's end_turn (docs/protocol.md,
  // "Needs you"), since API 14: what Mike has to do, which the phone shows
  // under the reply with its options as buttons. asksSeq says which card a
  // picked answer belongs to. Only web links: the phone can't open a file
  // on the Mac.
  asks: v.optional(
    v.array(
      v.object({
        action: v.string(),
        why: v.optional(v.string()),
        reply: v.optional(v.string()),
        options: v.optional(v.array(v.string())),
        suggested: v.optional(v.number()),
        links: v.optional(v.array(v.object({ title: v.string(), url: v.string() }))),
        ticked: v.optional(v.boolean()),
      }),
    ),
  ),
  asksSeq: v.optional(v.number()),
  // A finished turn's suggested follow-ups (end_turn's `next`), since API 14.
  next: v.optional(v.array(v.string())),
  // What the phone's sections need to match the Mac's (app ThreadSections),
  // since API 15: what the last turn said it needs, the design reviews
  // waiting on Mike, and whether it's waiting for a login with room.
  needs: v.optional(v.union(v.literal('you'), v.literal('nothing'))),
  pendingReviews: v.optional(v.number()),
  waitingForRoom: v.optional(v.object({ until: v.string(), accountId: v.optional(v.string()) })),
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
    // Whether Mike is at this Mac (the Mac app connected and the keyboard or
    // mouse used in the last two minutes), from sync:setPresence (API 3).
    // Only believed while lastSeenAt is recent: a sleeping Mac counts as away.
    atMac: v.optional(v.boolean()),
    atMacAt: v.optional(v.number()),
    // An SF Symbol for the runner's Mac ("laptopcomputer", "macmini"), so
    // lists can tell runners apart at a glance (API 10).
    icon: v.optional(v.string()),
    // How a Mac app reaches this runner to open one of its threads (API 12):
    // wss://<MagicDNS name>:<port>/rpc, only on the tailnet (sync.rpcUrl).
    rpcUrl: v.optional(v.string()),
  }).index('by_runnerId', ['runnerId']),

  // One small row per thread, just what a sidebar row shows (API 12), so a
  // Mac app can list other runners' threads without the busy fields of
  // `threads`: a runner writes a row only when one of these changes, apart
  // from preview and lastActivityAt, which ride along but never cause a
  // write (docs/step6-plan.md, part 2).
  threadIndex: defineTable({
    runnerId: v.string(),
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
    // Who started it, when that wasn't Mike: the row's byline. Since API 23.
    startedBy: v.optional(v.object({ kind: v.string(), label: v.string(), icon: v.optional(v.string()), threadTitle: v.optional(v.string()), why: v.optional(v.string()) })),
  })
    .index('by_runnerId', ['runnerId'])
    .index('by_runner_thread', ['runnerId', 'threadId']),

  // pushedAt is the mirror's own: when a push last went out for the thread
  // (push.ts), kept across the runner's writes.
  // pushHeldAt: a push to "when I'm away" phones held back because Mike was
  // at the Mac; it goes out if he leaves while the thread still needs him.
  threads: defineTable({ ...threadFields, view: v.union(...views.map((x) => v.literal(x))), pushedAt: v.optional(v.number()), pushHeldAt: v.optional(v.number()) })
    .index('by_threadId', ['threadId'])
    .index('by_share_slug', ['share.slug'])
    .index('by_runnerId', ['runnerId'])
    .index('by_view_activity', ['view', 'lastActivityMs'])
    // phone:search, for archived threads older than the phone's den list.
    .searchIndex('search_title', { searchField: 'title', filterFields: ['view'] })
    .searchIndex('search_preview', { searchField: 'preview', filterFields: ['view'] }),

  // The last 20 text messages of each thread (step 2), plus pages the
  // phone asked for, which a cron deletes a day later.
  // Every text message of every thread, and one line per tool call (role
  // "tool", since API 2; docs/setup-and-updates.md step 2). Tool output and
  // diffs stay on the Mac; pictures are in replyImages and shareImages. pagedAt marks rows an old phone asked
  // for with loadEarlier, so phone:thread still shows them to it for a day.
  messages: defineTable({
    threadId: v.string(),
    seq: v.number(),
    role: v.union(v.literal('user'), v.literal('assistant'), v.literal('tool')),
    text: v.string(),
    origin: v.optional(v.string()),
    toolKind: v.optional(v.string()), // the protocol's ToolKind, for a tool row
    summary: v.optional(v.boolean()), // end_turn's bullets, the turn's reply (since API 14)
    at: v.string(),
    pagedAt: v.optional(v.number()),
  })
    .index('by_thread_seq', ['threadId', 'seq'])
    .index('by_thread_pagedAt', ['threadId', 'pagedAt'])
    .index('by_pagedAt', ['pagedAt']),

  // What the phone asks a runner to do (step 3). The owning runner takes
  // pending ones for its runnerId (or "any"), applies them through the
  // same code the Mac app uses, and marks them done or failed.
  commands: defineTable({
    runnerId: v.string(), // or "any"
    threadId: v.optional(v.string()),
    kind: v.union(v.literal('send'), v.literal('respond'), v.literal('update'), v.literal('create'), v.literal('page'), v.literal('share'), v.literal('quickAsk')),
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

  // Phone tokens: only the hash is kept. Issued from the Mac app through
  // the runner (sync:issueToken) or by hand with
  // `npx convex run tokens:issue '{"name":"iphone","days":90}'`. `kind`
  // says whether a phone or a browser holds it (rows from before 28 Oct
  // have none: tokens.ts works it out from the name).
  tokens: defineTable({
    hash: v.string(),
    name: v.string(),
    kind: v.optional(v.union(v.literal('phone'), v.literal('browser'))),
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
    // The project's icon (docs/protocol.md, "Icons"), since API 5: its SF
    // Symbol, and `picture` naming the copy of its picture the runner has
    // put in projectIcons (the file's hash is in the name, so a changed
    // picture is a new name).
    icon: v.optional(v.object({ symbol: v.optional(v.string()), picture: v.optional(v.string()), by: v.string() })),
  }).index('by_runnerId', ['runnerId']),

  // The phone's Pocket: short cards agents file for when Mike's out
  // (API 19, the `pocket` tool). They live here rather than on a runner, so
  // both runners share one deck and the phone can remove one while the Mac
  // sleeps. `key` is the title in lower case: filing the same title again
  // replaces the card, whichever thread does it.
  pocketCards: defineTable({
    key: v.string(),
    title: v.string(),
    text: v.string(),
    place: v.optional(v.string()), // what to search the map for, to mark the card "here"
    icon: v.optional(v.string()), // since API 21: its picture and colour on the phone (runner/src/pocket-icons.ts)
    threadId: v.optional(v.string()),
    source: v.optional(v.string()), // the project or thread it came from, as it was then
    updatedAt: v.string(),
  }).index('by_key', ['key']),

  // A project's picture, in file storage, as the phone shows it: PNG at
  // most 256 px (an SVG is drawn to PNG by the runner, since the phone
  // can't draw SVG). One row per project; the runner replaces it when the
  // picture changes and setProjects drops it with the project.
  projectIcons: defineTable({
    runnerId: v.string(),
    projectId: v.string(),
    picture: v.string(), // the projects row's icon.picture this is
    storageId: v.id('_storage'),
    mediaType: v.string(),
    updatedAt: v.number(),
  }).index('by_runner_project', ['runnerId', 'projectId']),

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
    // Since API 9 a row can be the schedule itself rather than a runner's
    // mirror of its own file (docs/protocol.md, Schedules, "Runners"):
    // `owned` marks those, which only the sync:*Schedule functions write
    // and setSchedules never touches. They also keep what the mirror left
    // out, a run being sent (`claim`, which lapses at `until`), and a
    // schedules.run made on another runner (`runRequestedAt`).
    owned: v.optional(v.boolean()),
    effort: v.optional(v.string()),
    permissionMode: v.optional(v.string()),
    createdBy: v.optional(v.string()),
    claim: v.optional(v.object({ holder: v.string(), until: v.number() })),
    runRequestedAt: v.optional(v.string()),
  })
    .index('by_runnerId', ['runnerId'])
    .index('by_scheduleId', ['id']),

  accounts: defineTable({
    runnerId: v.string(),
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
  }).index('by_runnerId', ['runnerId']),

  // APNs tokens for push (step 4), one row per phone install.
  devices: defineTable({
    apnsToken: v.string(),
    environment: v.union(v.literal('sandbox'), v.literal('production')),
    tokenName: v.string(),
    updatedAt: v.number(),
    // When this phone wants a push (phone:setNotifications, API 3):
    // "away" (the default) only while Mike isn't at the Mac, "always", or "off".
    notify: v.optional(v.union(v.literal('away'), v.literal('always'), v.literal('off'))),
    // The phone's own key for encrypting what goes through the push relay
    // (API 4): base64 of 32 bytes, made on the phone and sent only here.
    pushKey: v.optional(v.string()),
  }).index('by_apnsToken', ['apnsToken']),

  // The pictures of a shared thread (API 8), in file storage, uploaded by
  // the runner while the thread is shared and dropped when it stops
  // (sync:addShareImage, sync:dropShareImages). `path` is the file on the
  // Mac it came from, so the runner sends each once; `src` is set for one
  // the agent wrote into its text as Markdown, the address the page swaps.
  shareImages: defineTable({
    threadId: v.string(),
    seq: v.number(),
    path: v.string(),
    src: v.optional(v.string()),
    storageId: v.id('_storage'),
    mediaType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  }).index('by_thread_seq', ['threadId', 'seq']),

  // Pictures an agent showed Mike, for the phone (API 24), from any thread:
  // ones in its replies (`src`, the address it wrote, which the phone swaps)
  // and image files it pinned (`pinned`). In file storage, uploaded by the
  // runner, and gone with the thread (sync:removeThreads). Apart from
  // shareImages, as stopping sharing drops those and readers of a shared
  // page must only ever get what was uploaded for it.
  replyImages: defineTable({
    threadId: v.string(),
    seq: v.number(),
    path: v.string(),
    src: v.optional(v.string()),
    pinned: v.optional(v.boolean()),
    storageId: v.id('_storage'),
    mediaType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  }).index('by_thread_seq', ['threadId', 'seq']),

  // This backend's registration with the push relay (docs/push-relay.md),
  // made the first time a push goes that way. One row.
  relayInstall: defineTable({
    installId: v.string(),
    installKey: v.string(),
    url: v.string(),
    createdAt: v.number(),
  }),
});
