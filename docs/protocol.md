# Runner protocol (v1)

The app and the runner talk JSON-RPC 2.0 over a WebSocket at
`ws://127.0.0.1:8797/rpc`. One JSON object per WebSocket text message.
Both sides must ignore unknown fields and unknown event types so either can be
upgraded first. Times are ISO 8601 strings in UTC. Ids are strings.

## Auth

Send `Authorization: Bearer <token>` on the upgrade request. The token is the
contents of `~/Library/Application Support/Threadbare/secrets/runner-token`.
If a client can't set headers, its first message may be
`{"jsonrpc":"2.0","id":1,"method":"auth","params":{"token":"..."}}`.
Anything else before auth (including a binary frame, or nothing for 5
seconds) closes the socket with code 4401.

## Types

```ts
type Provider = "claude" | "codex"

type Account = {
  id: string            // "claude-main", "claude-1", "codex-main", "codex-1", ...
  provider: Provider
  title: string         // Claude: the email when known, else the id. Codex:
                        // "Codex · <email>", so an app that only reads title
                        // can tell it from a Claude login with the same address
  configDir: string
  defaultModel?: string // full id of the model a thread with no model runs on
                        // ("claude-fable-5-1"): the account's own setting
                        // (Codex: config.toml's model, else the model list's
                        // default), corrected by the first turn the runner
                        // sees. Absent until the runner knows
  models?: ModelChoice[] // what the account's CLI offers, in its own order,
                        // once the runner has asked it (a few seconds after
                        // it starts). Codex: its model list without hidden models
  defaultEffort?: EffortLevel // the account's own level (Codex: config.toml's
                        // model_reasoning_effort). Absent: each model's own
  email?: string        // the bare address, when known
  plan?: string         // "Max", "Team", "Pro Lite"
  note?: string         // Mike's own note for the account ("Convex work only")
  usage?: AccountUsage  // absent when nothing is known (and from older runners)
}

// "ultra" is Codex's multi-agent level. Claude never offers it.
type EffortLevel = "low" | "medium" | "high" | "xhigh" | "max" | "ultra"

type ModelChoice = {
  id: string            // what to send as `model` ("opus", "claude-fable-5-1[1m]", "gpt-6-luna")
  model: string         // the full id it runs as ("claude-opus-5-5")
  title: string         // "Opus 5.5"
  description?: string
  effortLevels?: EffortLevel[] // absent when the model takes no effort level
  defaultEffort?: EffortLevel  // the model's own level, when the CLI says (Codex)
}

type UsageWindow = {
  kind: "five_hour" | "weekly" | "weekly_model" | "daily" | "monthly" | "allowance" | "other"
  title: string         // "5-hour", "Weekly", "Weekly Fable", "$250 allowance"
  remainingPercent: number // 0 to 100, may be fractional
  resetsAt?: string
  detail?: string       // "$132.79 left"
}

type AccountUsage = {
  windows: UsageWindow[]
  readAt: string        // when the newest reading in it was taken
  source: "tokenStats" | "live" // where the newest reading came from: Token
                        // Stats' limits.json, or the account's own turns
  stale?: boolean       // Token Stats hasn't written for 15 minutes and
                        // there's no live reading since
  blocked?: boolean     // the provider says this login is at its limit
  notice?: string       // Token Stats' own note ("64,390 credits · 2 limit resets available")
}

type CliStatus = {
  provider: Provider
  path: string          // the binary new sessions start
  managedBy: "threadbare" | "cli" | "none" // Codex: Threadbare's own copies;
                        // Claude: its own installer; "none": codexPath set by
                        // hand, never updated
  installedVersion?: string // what new sessions start on
  latestVersion?: string
  status: "current" | "behind" | "held" | "unknown" | "missing"
  policy: "auto" | "notify" | "off"
  inUse: { version: string, threadIds: string[] }[] // versions live sessions run
  previousVersion?: string  // Codex: the kept version "Go back" returns to
  checkedAt?: string
  hold?: { version: string, reason: string, missing?: string[] } // why an
                        // update wasn't installed by itself ("the app-server
                        // protocol changed", with what it lost)
  update?: {            // the latest update, while it runs and after
    state: "waiting" | "running" | "succeeded" | "unchanged" | "failed"
    targetVersion?: string
    waitingFor?: string[]
    finishedAt?: string
    message?: string
  }
}

type ThreadStatus =
  | "idle"              // no turn running (CLI may or may not be live)
  | "starting"          // CLI spawning or resuming
  | "running"           // a turn is in progress
  | "waiting"           // blocked on an approval or a question
  | "error"             // last turn failed; can still send
  | "stopped"           // runner restarted mid-turn

type ThreadSummary = {
  id: string
  title: string
  cwd: string
  accountId: string
  provider: Provider    // always the account's provider
  model?: string        // undefined means the account's default
  effort?: EffortLevel  // undefined means the model's own level
  modelInUse?: string   // full id the CLI ran the last turn on, once one has run
  effortInUse?: EffortLevel // the level the CLI reported for the last turn
  permissionMode: "full" | "ask"
  status: ThreadStatus
  live: boolean         // a CLI process is attached right now
  needsYou: boolean     // waiting, or a turn finished after lastSeenSeq
  createdAt: string
  updatedAt: string
  lastActivityAt: string
  snoozedUntil?: string
  snoozedUntilRestart?: true // hibernating until the runner next starts;
                        // snoozedUntil is then 9999-12-31T00:00:00.000Z
  archivedAt?: string
  onOldRunner?: true    // finishing a turn on the runner that handed over
                        // (Handovers); moves across when the turn ends
  preview: string       // last assistant text, one line, <= 140 chars
  lastSeq: number       // seq of the newest persisted event
  lastSeenSeq: number
  nativeSessionId?: string
  contextTokens?: number
  contextWindow?: number // the model's context window, when the CLI reports it
  costUsd?: number      // total for the thread so far, if known (Codex reports none)
  panels?: Panel[]      // from the folder's patches (see Patches); absent when there are none
  actions?: Action[]    // likewise
  hooks?: Hook[]        // likewise
  patches?: PatchInfo[] // the patches that apply to the folder; absent when there are none
  background?: BackgroundTask[] // what the live CLI is still running in
                        // the background: sub-agents and shell jobs
                        // started with run_in_background, Monitor and the
                        // like, and ones just finished whose result the
                        // agent hasn't read yet. Absent when there's none.
                        // Set during a turn too; between turns it's the
                        // sign the thread is still being worked on
  subagents?: Subagent[] // the sub-agents the agent has started, foreground
                        // and background: the newest 20, oldest first.
                        // Absent when it has started none
  projects?: ThreadProject[] // the projects the thread is in (see Projects),
                        // oldest first. Absent when it's in none
}

// A project a thread is in, as its summary shows it.
type ThreadProject = {
  id: string
  title: string
  by: "mike" | "agent" | "librarian" // who put it there
  pinned?: boolean      // Mike put it there (or an agent was told to): the
                        // librarian won't take it out
  at: string            // when it was put there
}

type Action = {
  id: string            // "<patch>.<slug of the title>": "reseed.reseed-dev-db"
  title: string
  kind: "command" | "prompt"
  command?: string      // kind "command": run by `actions.run`, in `folder`
  prompt?: string       // kind "prompt": sent to the thread as a message by `actions.run`
  patch: string
  folder?: string       // where the command runs: the project folder the
                        // patch came from. Absent: the thread's own folder
  projectId?: string    // the project whose folder gave it (see Projects)
  note?: string
}

type Hook = {
  id: string            // "<patch>.<slug of the title>"
  title: string
  on: "turn.end"        // when it runs: after a turn the agent completed (not one it was interrupted in, or failed)
  command: string       // run in `folder`, as an action's command is
  edited?: string       // only after a turn that edited a file matching this glob, relative to `folder` ("**/*.ts")
  tell: "failures" | "always" | "never"  // when its result is sent to the agent as a message (see Patches)
  patch: string
  folder?: string       // as Action's; a hook from a project folder only
                        // sees edits inside that folder
  projectId?: string
  note?: string
}

type PatchInfo = {
  id: string            // "convex", "xcode", or a patch file's name without its extension
  source: "builtin" | "home" | "project"
  file?: string         // the module, for home and project patches
  folder?: string       // set (with projectId) when it came from one of
                        // the thread's projects' folders rather than its
                        // own: the folder holding `.threadbear/`, or a
                        // built-in's project folder
  projectId?: string
  error?: string        // the file couldn't be loaded, and gives nothing until it's fixed
}

type Panel = {
  id: string            // unique within the thread: "convex.dashboard", "xcode.simulator"
  title: string         // the tab's label
  kind: "url" | "image" // a page in a web view, or a picture the runner draws on request
  url?: string          // kind "url": the page; also what Open in browser opens
  patch: string         // the patch it came from: "convex", "xcode"
  projectId?: string    // as Action's
  note?: string         // one line about it: the deployment, the project
}

// A grouping above folders that carries goals, state and notes forward
// (see Projects).
type Project = {
  id: string            // "p_" and 8 hex characters
  title: string
  folders: string[]     // absolute paths, in the order patches load from them
  goals: string         // a few lines: what it's for, what done looks like
  state: string         // a few lines: where it's up to, what's next
  notes: string         // markdown: decisions, gotchas, commands, links
  createdBy: "mike" | "agent" | "librarian"
  createdByThread?: string // the thread whose agent or look made it
  createdAt: string
  updatedAt: string
  stateUpdatedAt?: string
  archived?: boolean
  threadCount: number   // threads in it, put away ones included
  lastActivityAt?: string // its newest thread's lastActivityAt
}

// What the librarian (see Projects) is doing, has done and will do next.
type LibrarianStatus = {
  state: "idle" | "working" | "paused" | "off"
  reason?: string       // state "off": why ("No OpenRouter key", "Today's
                        // model budget is spent", "Model calls are off")
  paused: boolean       // Mike paused it; looks wait in the queue
  current?: LibrarianJob & { startedAt: string } // the look under way
  queue: LibrarianJob[] // what it will look at next, soonest first
  recent: LibrarianEntry[] // what it did, newest first, the last 50
  looksToday: number
  spentTodayUsd: number // its share of the day's model spend
}

type LibrarianReason =
  | "first-turn"        // a thread's first turn ended
  | "new-folder"        // a turn edited files outside the thread's projects' folders
  | "moved"             // the thread changed folder
  | "catch-up"          // more turns since its last look (at most hourly)
  | "asked"             // librarian.run, or a backfill

type LibrarianJob = {
  threadId: string
  threadTitle: string
  reason: LibrarianReason
  why: string           // the reason in words: "Edited files in ~/dev/me/poddle"
  dueAt: string
}

type LibrarianEntry = {
  id: string
  at: string
  threadId: string
  threadTitle: string
  reason: LibrarianReason
  outcome: "joined" | "created" | "updated" | "left" | "nothing" | "skipped" | "failed"
  text: string          // "Put it in Threadbear", "Made Poddle and put it there",
                        // "Threadbear's state", "No key", the model's error
  projectIds?: string[]
  costUsd?: number
}


// A sub-agent the thread's agent started (Claude's Agent tool). The runner
// follows it from the CLI's task events, so it changes while it runs: each
// change sends thread.updated. `threads.subagent` reads what it did.
type Subagent = {
  id: string            // the CLI's id for it (its task id)
  itemId?: string       // the tool.call that started it, in the thread
  parentId?: string     // the sub-agent that started this one, when it was
                        // started by a sub-agent rather than the thread's agent
  description: string   // its brief's title: "Review the runner changes"
  agentType?: string    // "general-purpose", "Explore", "fork"
  status: "running" | "completed" | "failed" | "stopped"
                        // clients treat a status they don't know as stopped
  background: boolean   // the agent carried on while it ran
  activity?: string     // while running, what it's doing in the CLI's own
                        // words ("Running npm test")
  summary?: string      // once finished, what it reported, one line, <= 200 chars
  toolUses?: number     // tool calls so far
  startedAt: string
  endedAt?: string      // set once it's no longer running
}

type BackgroundTask = {
  kind: "agent" | "shell" | "monitor" | "other" // a sub-agent, a shell
                        // command, a Monitor, or anything else the CLI
                        // runs in the background (a workflow). Clients
                        // treat a kind they don't know as "other"
  description: string   // the CLI's own words: the sub-agent's brief, the
                        // command. May be empty
  finished?: boolean    // true once it has finished and the agent is about
                        // to start a turn of its own to read its result
                        // (the runner counts it for up to 15 s, until that
                        // turn starts)
}

type ImageRef = {
  path: string          // absolute path on this Mac
  mediaType: string     // "image/png", "image/jpeg", "image/gif", "image/webp"
  width?: number
  height?: number
}

type Schedule = {
  id: string
  title: string         // for lists; default the first line of text
  text: string          // the message it sends each time
  at?: string           // a one-off: when it runs
  cron?: string         // or repeating: a 5-field cron ("0 9 * * 1-5"), or
                        // @hourly, @daily, @weekly, @monthly, @yearly
  timezone?: string     // IANA zone the cron is read in; absent means the
                        // Mac's own zone, whatever it is at the time
  whenText: string      // "Weekdays at 9:00", "Once, Tue 28 Oct at 15:30":
                        // the runner's words for at/cron, for every client
  threadId?: string     // sends to this thread. Absent: starts a new thread
                        // each time, with the settings below
  cwd?: string          // new-thread settings, as in threads.create
  accountId?: string
  model?: string
  effort?: EffortLevel
  permissionMode?: "full" | "ask"
  paused: boolean
  createdAt: string
  updatedAt: string
  createdBy?: string    // the thread whose agent made it; absent for a person
  nextRunAt?: string    // absent while paused, or once a one-off has run
  finishedAt?: string   // a one-off that has run (kept for 7 days, then dropped)
  runs: number          // how many times it has sent its message
  lastRun?: {
    at: string
    outcome: "sent" | "skipped" | "failed"
    threadId?: string   // the thread it sent to or started
    note?: string       // why it was skipped or failed
  }
}

// The runner's settings, as the Settings window shows them. Everything here
// is kept in runner.json except the key, which only the runner ever reads.
type Settings = {
  defaultCwd: string    // where a new thread starts when it names no folder
  idleMinutes: number   // a CLI with no turn for this long is released
  maxLiveCLIs: number   // most CLIs kept live at once
  followMain: boolean   // build and restart onto main by itself; a change
                        // takes effect when the runner next restarts
  models: {
    openRouterKey: { set: boolean, hint?: string } // hint: the key's last 4 characters
    dailyBudgetUsd: number   // 1 by default; 0 turns model calls off
    spentTodayUsd: number    // since local midnight
    spentMonthUsd: number    // since the 1st, local time
    privateFolders: string[] // folders (and everything under them) whose
                             // text is never sent; "~/" paths as written
  }
}
```

## Events

Every persisted event has an envelope:

```ts
type Event = {
  seq: number           // 1, 2, 3 ... per thread, no gaps among persisted events
  ts: string
  threadId: string
  turnId?: string
  type: string
  // ...type-specific fields below
}
```

Persisted event types (stored in `events.ndjson`, returned by `threads.events`):

| type | fields |
|---|---|
| `user.message` | `text`, `images: ImageRef[]`, `origin?: "runner" \| "schedule"` (`runner` when the runner sent the message by itself, such as the resume after a restart; `schedule` when a schedule sent it, with `scheduleId`; absent for anything a person or client sent), `scheduleId?` |
| `assistant.text` | `itemId`, `text` (complete markdown for that block) |
| `reasoning` | `itemId`, `text` (summary) |
| `tool.call` | `itemId`, `name` (raw tool name), `kind` (`command` \| `read` \| `edit` \| `write` \| `search` \| `web` \| `mcp` \| `task` \| `todo` \| `image` \| `other`; `image` is image generation), `title` (one line, e.g. "npm test" or "Edit src/a.ts"), `input` (object, large strings truncated to 16 KB) |
| `tool.result` | `itemId` (matches the call), `ok`, `text` (truncated to 64 KB), `truncated`, `blobPath?`, `images: ImageRef[]` |
| `edit.diff` | `itemId`, `path`, `hunks: {oldStart, oldLines, newStart, newLines, lines: string[]}[]` (lines start with " ", "-" or "+"); sent after `tool.call` for Edit/MultiEdit/Write when the runner can compute it. One event per file: a tool that changes several files (a Codex patch) has one per path. A later `edit.diff` with the same `itemId` and `path` replaces that file's diff; a new path adds one |
| `approval.requested` | `approvalId`, `itemId?` (absent for a subagent's tools, which have no `tool.call`), `name`, `title`, `input`, `options: ("allow" \| "allowAlways" \| "deny")[]` |
| `question.requested` | `approvalId`, `questions: {question, header?, multiSelect, options: {label, description?}[]}[]` |
| `approval.resolved` | `approvalId`, `decision` (`allow` \| `allowAlways` \| `deny` \| `answered` \| `expired`), `message?` |
| `plan.updated` | `entries: {text, status: "pending" \| "in_progress" \| "completed"}[]` |
| `turn.started` | `turnId`. A turn the agent starts by itself (a background task finished, or a background subagent needs an approval) has no `user.message` before it. A `user.message` after `turn.started` was sent while the turn ran and went into it |
| `turn.completed` | `turnId`, `outcome` (`completed` \| `interrupted` \| `failed`), `durationMs`, `costUsd?` (Codex turns have none), `usage?` (Claude: `{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`; Codex: `{inputTokens, cachedInputTokens, cacheWriteTokens?, outputTokens, reasoningTokens}`), `error?`, `errorKind?` (`usageLimit` \| `contextWindow` \| `auth`, when a failed turn's cause is known, so a client can offer the fix without reading `error`) |
| `system.note` | `text` (e.g. "Resumed session", "Compacted the conversation", "Patch reseed added: action Reseed dev DB.") |
| `error` | `message` |
| `action.run` | `actionId`, `patch`, `title`, `command`, `ok`, `exitCode?`, `text` (what it printed, truncated to 64 KB), `truncated`, `durationMs`, `trigger?` (`"turn.end"` when a hook ran it; absent for a chip or `tb run`). A command that `actions.run` or a hook ran; outside any turn unless one was running, in which case it carries that `turnId` |

Transient events are only sent to subscribers, never persisted, and carry
`seq` of the last persisted event (they don't consume a number):

| type | fields |
|---|---|
| `assistant.text.delta` | `itemId`, `text` (append) |
| `reasoning.delta` | `itemId`, `text` (append) |
| `tool.output.delta` | `itemId`, `text` (append, for long-running commands if available) |

When an item completes, its persisted event (`assistant.text`, `reasoning`)
replaces whatever the deltas built up.

## Requests (app to runner)

| method | params | result |
|---|---|---|
| `hello` | `{ client: string, version: string }` | `{ runnerVersion, protocol: 1, accounts: Account[], defaults: { cwd, accountId, model?, models?: { claude?, codex? }, efforts?: { claude?: EffortLevel, codex?: EffortLevel } }, clis?: CliStatus[], updates?: RunnerUpdates }`. `updates` is under Runner updates. `defaults.accountId` is the account a `threads.create` with no `accountId` uses: the one with the most room among the last-used account's provider (skipping blocked ones, ones under 10% and ones with a note), worked out again as usage changes; a client keeps its own copy of the rule rather than asking again. `defaults.models[provider]` is the model a new thread on that provider gets when it names none (`runner.json`'s `defaults.models`; a dev runner sets the cheapest); `defaults.model` is the same for Claude, kept for older apps. Absent means the account's own default (`accounts[].defaultModel` names it, when known). `defaults.efforts[provider]` likewise for effort; absent means the model's own level. `runnerVersion` is `<package version>+<release id>` when the runner runs from a release, else `<package version>+source` |
| `threads.list` | `{ include?: ("inbox" \| "snoozed" \| "archived")[] }` (default `["inbox"]`) | `{ threads: ThreadSummary[] }` newest activity first |
| `threads.search` | `{ query: string, limit?: number }` | `{ threads: ThreadSummary[] }` matches title and preview across all threads, archived included |
| `threads.create` | `{ text: string, images?: ImageRef[], cwd?: string, accountId?: string, model?: string, effort?: EffortLevel, permissionMode?: "full" \| "ask", title?: string }` | `{ thread: ThreadSummary }` (the first turn starts straight away). The thread's `provider` is its account's. With no `model`, the thread gets `defaults.models[provider]` from `hello`, or `defaults.model` for Claude, or else the account's own default. With no `effort`, `defaults.efforts[provider]`, or else the model's own level. See "Models and effort across providers" |
| `threads.send` | `{ threadId, text, images?: ImageRef[] }` | `{ turnId }`. If a turn is running and its CLI is live, the message goes into that turn straight away (a `user.message` under the running `turnId`, which is returned): the agent takes it at its next step, or right after its reply if that was already finishing, and the turn doesn't complete until it has been answered. Otherwise (the CLI is still starting or leaving, messages are already waiting, a move or fresh CLI is due on the next turn, Stop has been pressed, or the turn is only an approval for a background subagent) the message is queued and starts its own turn when the running one ends |
| `threads.interrupt` | `{ threadId }` | `{}` |
| `threads.update` | `{ threadId, title?, cwd?, accountId?, model?: string \| null, effort?: EffortLevel \| null, permissionMode?, snoozedUntil?: string \| null, archived?: boolean }` | `{ thread: ThreadSummary }`. `snoozedUntil` is an ISO time, or `"restart"` for until the runner next starts (any start: a planned restart, a crash, a reboot), when the thread wakes before the restart's resume is sent, so a thread put away while its own restart waited is still carried on. Snoozing or archiving releases the CLI (and archives a Codex thread in Codex too). Changing account or cwd takes effect on the next turn. A model or effort change reaches a live Claude CLI straight away (`null` goes back to the default); on Codex it applies from the next turn, with a `system.note` if a turn is running. A folder change on the same Claude account copies the native session's transcript to the new folder and resumes it; on the same Codex account the session carries on in the new folder from the next turn. Otherwise (or if that fails) it starts a new native session with a short handoff note. An account of the other provider switches `provider`, resets `model` and `effort` to that provider's defaults unless the same call sets them, and clears the thread's "Always allow" rules. `model` and `effort` are checked as in "Models and effort across providers" |
| `threads.retitle` | `{ dryRun?: boolean, threadIds?: string[] }` | `{ threads: { threadId, from: string, to?: string, reason?: string }[] }`. Gives a model title to every thread, archived and snoozed included, whose title is still its first message's first line and that nobody has named (`titleSet`); see "Titles" under "Settings and models". One entry per such thread: `to` when it was renamed, `reason` when it wasn't (no key, private folder, over budget, renamed meanwhile). With `threadIds`, those threads whatever their title (a poor model title can be asked for again), still never one named by hand. The model also gets the start of the thread's first reply. `dryRun` lists them without asking the model (`tb retitle`) |
| `threads.delete` | `{ threadId }` | `{}`. Stops the thread's CLI and moves its folder to `trash/` in the data dir (a Codex thread is archived in Codex too). Every client gets `thread.deleted` |
| `threads.events` | `{ threadId, afterSeq?: number, beforeSeq?: number, limit?: number }` (default: the newest 500) | `{ events: Event[], firstSeq, lastSeq, inProgress: { itemId, type: "assistant.text" \| "reasoning", text }[] }` |
| `threads.subscribe` | `{ threadId, afterSeq?: number }` | `{ events: Event[], inProgress: { itemId, type, text }[] }` (everything after `afterSeq`, and the text streamed so far for items still streaming), then pushes `thread.event` notifications. Deltas pushed after the reply carry on from `inProgress` |
| `threads.unsubscribe` | `{ threadId }` | `{}` |
| `threads.subagent` | `{ threadId, subagentId }` | `{ subagent?: Subagent, events: Event[] }`: what the sub-agent has done so far, read from the CLI's own record of it, as events (`user.message` for its brief, then `assistant.text`, `reasoning`, `tool.call`, `tool.result`, `edit.diff`) numbered from 1, with no `turnId`. Read again for more while it runs: thread.updated says when it has done something. `subagent` is absent once the thread's list has dropped it. `-32006` when there's no record of it (an older thread, or the CLI cleaned it up) |
| `threads.markSeen` | `{ threadId, seq }` | `{ thread: ThreadSummary }` |
| `approvals.respond` | `{ threadId, approvalId, decision: "allow" \| "allowAlways" \| "deny" \| "answered", message?: string, answers?: Record<string, string> }` | `{}`. `allowAlways` allows matching requests for the rest of this thread only; it never changes the thread's permission mode or saves anything in the project. With `answered`, the app sends the chosen answers in one line as `message` too: the runner keeps it in `approval.resolved` (only `answers` goes to the CLI), so the transcript can show what was chosen |
| `media.import` | `{ path: string }` | `{ image: ImageRef }` copies a file into `inbox/` and reads its size |
| `actions.run` | `{ threadId, actionId }` | For a prompt action, `{ turnId }`: its prompt was sent as a message (as `threads.send`). For a command action, `{ ok, exitCode?, durationMs, seq }` once the command has finished, with its output in the transcript as the `action.run` event at `seq`. The command runs in the thread's folder through a login shell with the thread's variables (`THREADBARE_THREAD_ID` and the rest) and is stopped after 10 minutes. `-32602` for an action the thread doesn't have, `-32020` while the same action is still running |
| `panels.render` | `{ threadId, panelId }` | `{ image?: ImageRef, note?: string }` draws an `image` panel now: for `xcode.simulator`, a screenshot of the booted simulator (`xcrun simctl io booted screenshot`), written to the same file each time under the thread's `panels/`. With no device booted (or another failure) there's only `note`. Slow: it waits for the screenshot. `-32602` for a panel the thread doesn't have |
| `schedules.list` | `{ threadId?: string }` | `{ schedules: Schedule[] }`, soonest `nextRunAt` first, then the paused and finished ones. With `threadId`, only the ones that send to that thread or were made by it |
| `schedules.create` | `{ text: string, title?: string, at?: string, cron?: string, timezone?: string, threadId?: string, cwd?, accountId?, model?, effort?, permissionMode?, paused?: boolean, createdBy?: string }` | `{ schedule: Schedule }`. Exactly one of `at` and `cron`. An `at` in the past runs straight away. With `threadId` it sends there, otherwise it starts a new thread each time (`cwd` defaults like `threads.create`'s, checked now). A bad cron or zone is `-32602` with a message saying what's wrong |
| `schedules.update` | `{ scheduleId, title?, text?, at?: string, cron?: string, timezone?: string \| null, paused?: boolean, cwd?, accountId?, model?: string \| null, effort?: EffortLevel \| null, permissionMode? }` | `{ schedule: Schedule }`. Setting `at` drops `cron` and the other way round. A new time works out `nextRunAt` again; so does unpausing. Setting `at` on a finished one-off makes it run again then. The target thread can't be changed (make a new schedule) |
| `schedules.delete` | `{ scheduleId }` | `{}` |
| `schedules.run` | `{ scheduleId }` | `{ schedule: Schedule, threadId: string, turnId: string }` runs it now, as if it were due, even when paused. A repeating schedule keeps its `nextRunAt`; a one-off is finished |
| `schedules.preview` | `{ cron?: string, at?: string, timezone?: string, count?: number }` | `{ whenText: string, runs: string[] }`, the next `count` (default 5, at most 20) times it would run, for an editor to show as someone types. `-32602` with the reason for a cron or zone it can't read |
| `projects.list` | `{ archived?: boolean }` | `{ projects: Project[] }`, newest `lastActivityAt` first. Archived ones only with `archived: true` (then all of them) |
| `projects.get` | `{ projectId }` | `{ project: Project, threadIds: string[] }`, its threads newest activity first, put away ones included |
| `projects.create` | `{ title: string, folders?: string[], goals?, state?, notes?, threadIds?: string[] }` | `{ project: Project }`, made by Mike (`createdBy: "mike"`). `threadIds` are put in it, pinned. Folders must exist (`-32602` otherwise) |
| `projects.update` | `{ projectId, title?, folders?: string[], goals?, state?, notes?, archived?: boolean }` | `{ project: Project }`. Replaces what's given. A change of folders reloads its threads' patches |
| `projects.merge` | `{ projectId, intoId }` | `{ project: Project }` (the one kept). Folders and threads move over, notes are joined, and `projectId` is deleted |
| `projects.delete` | `{ projectId }` | `{}`. Its threads leave it; nothing else is touched |
| `threads.setProjects` | `{ threadId, add?: string[], remove?: string[] }` | `{ thread: ThreadSummary }`. What Mike does by hand: an added project is pinned (adding one the thread is already in pins it, which is how "keep it here" works), a removed one is remembered so the librarian never puts the thread back in it |
| `librarian.status` | `{}` | `{ librarian: LibrarianStatus }` |
| `librarian.run` | `{ threadId?: string }` | `{ librarian: LibrarianStatus }`. Queues a look at the thread now (reason `asked`), or with no `threadId`, at every thread it has never looked at (a backfill, newest first) |
| `librarian.update` | `{ paused?: boolean }` | `{ librarian: LibrarianStatus }` |
| `settings.get` | `{}` | `{ settings: Settings }` |
| `settings.update` | `{ defaultCwd?, idleMinutes?, maxLiveCLIs?, followMain?, models?: { dailyBudgetUsd?, privateFolders? } }` | `{ settings: Settings }`. Saves what's given to `runner.json` and applies it straight away, except `followMain` (next restart). `defaultCwd` must be an existing folder, `idleMinutes` at least 1, `maxLiveCLIs` 1 to 20, `dailyBudgetUsd` 0 to 100; otherwise `-32602` saying which. Every client gets `settings.updated` |
| `settings.setKey` | `{ provider: "openrouter", key: string \| null }` | `{ settings: Settings }`. Writes the key to `secrets/openrouter-key` (0600), or removes it for `null`. The key is never sent back, only `set` and `hint`. A key with spaces inside or under 20 characters is `-32602`. Every client gets `settings.updated` |
| `models.run` | `{ job: "classify" \| "extract" \| "summarize" \| "generate", text: string, labels?: string[], fields?: Record<string, string>, maxWords?: number, system?: string, cwd?: string, maxTokens?: number }` | `{ ok: true, value, model, costUsd? }` or `{ ok: false, reason: "no-key" \| "off" \| "private" \| "over-budget" \| "timeout" \| "provider", message }`. One model call by hand (`tb models try`), spent and counted like any other, with `feature: "tb"`. `maxTokens` (generate only, 1 to 8000, default 500) caps the answer, reasoning included; `classify` needs 2 or more `labels` and answers one of them; `extract` needs `fields` (name to a plain description) and answers an object of them, `null` where the text doesn't say |
| `runner.status` | `{}` | `{ version, release?, branch?, pid, startedAt, home, logFile, liveClis, running: string[], background: { threadId, tasks: string[] }[], pendingRestart?: { when, reason?, release?, resumeThreadId?, requestedAt, backgroundUntil?, waitingFor: string[] }, rolledBack?: { from, at }, draining?: { pid, version, release?, since, threads: string[] }[], update?: { state, checkout?, reason?, checkedAt?, commit?, release?, logFile? }, clis?: CliStatus[] }`. `running` lists the threads that are starting, running or waiting on an approval or a question; `background` the threads whose CLI is still running background shells or subagents (`tasks` describes each). A restart waits for both. `branch` is the branch the release was built from. `rolledBack` is set when this release is running because `launch.mjs` went back to it from `from`, which kept crashing at startup (and nobody has activated it on purpose since). `update` is the runner following main by itself (docs/dev-tools.md): `state` is `off` (`reason` says why), `idle`, `checking`, `building`, `waiting` (`release` is built and starts on the pending restart) or `failed` (`reason` is the error; `logFile` has the build's output); `commit` is main's tip at the last check (`checkedAt`) |
| `runner.restart` | `{ when?: "idle" \| "now", resume?: { threadId, text }, reason?: string, release?: string, backgroundWaitMs?: number, cancel?: boolean }` | `{ scheduled: boolean, waitingFor: string[], background?: { threadId, tasks: string[] }[], note?: string, noResume?: string, handover?: { keeps: string[] } }`. See Restarts below; `handover` under Handovers. `scheduled` is true once the restart is saved; an empty `waitingFor` means it is happening now. `background` is the background work among `waitingFor`. `release` is the release the restart should come back on (the deploy script sets it). `backgroundWaitMs` limits how long background shells and subagents hold the restart. `cancel: true` withdraws a pending restart that hasn't begun and returns `scheduled: false` (`-32020` once it has begun), with a `note` when it also put `current` back. `noResume` says why the `resume` won't be sent as things stand (the thread has already been resumed 3 times in the last hour), so whoever asked can say so rather than wait for it. A runner older than this answers `-32601` |
| `clis.list` | `{}` | `{ clis: CliStatus[] }` |
| `clis.check` | `{ provider?: Provider }` | `{ clis: CliStatus[] }`. Starts a version check (both CLIs when `provider` is absent) and returns at once, with the state as it was when the call arrived; the result comes through `clis.updated` |
| `clis.update` | `{ provider: Provider, version?: string, force?: boolean }` | `{ clis: CliStatus[] }`. Starts an update and returns at once, with `update.state` `running` or `waiting`; progress comes through `clis.updated`. `version` picks a kept Codex version (how "Go back" works). `force: true` installs a held version anyway |
| `clis.setPolicy` | `{ provider: Provider, policy: "auto" \| "notify" \| "off" }` | `{ clis: CliStatus[] }` |

Errors use JSON-RPC error objects: `-32602` bad params, `-32004` thread not
found, `-32005` schedule not found, `-32006` sub-agent not found, `-32007` project not found, `-32010` account not found, `-32020` busy (e.g. two sends racing), `-32030` a draining runner no longer holds that thread (Handovers),
`-32601` a method this runner doesn't have (`clis.*` on a runner older than
them), `-32000` anything else with a readable `message`.

### Models and effort across providers

The runner checks `model` and `effort` in `threads.create` and
`threads.update` against the thread's provider, and corrects them rather than
answering `-32602`, because an older app always sends a model and can't
recover from an error. (An `effort` that isn't an `EffortLevel` at all is
still `-32602`.)

- Claude models are `opus`, `sonnet`, `haiku` and anything starting
  `claude-`. Codex models are those in a Codex account's `models`, or
  anything starting `gpt-` before the list is known.
- A model of the other provider, or a Codex id that isn't in the account's
  `models` once they're known, is replaced by the provider's default, with a
  `system.note` ("sonnet isn't a Codex model, so this thread uses
  GPT-6.1-Sol").
- An effort the model doesn't list in `effortLevels` (when known) is dropped
  with a note. `ultra` on a Claude thread always is.

## Notifications (runner to app)

| method | params |
|---|---|
| `thread.updated` | `{ thread: ThreadSummary }` sent to every connected client whenever a summary changes, `background` included: a sub-agent or shell job starting or finishing sends one even when nothing else changed |
| `thread.event` | `{ threadId, event: Event }` only for subscribed threads, persisted and transient |
| `thread.deleted` | `{ threadId }` sent to every connected client when a thread is deleted |
| `accounts.updated` | `{ accounts: Account[] }` sent to every connected client when the account list or what the runner knows about an account changes: a login appears or goes (checked every 10 seconds), its `models` once the CLI has been asked, its `defaultModel` once a turn has shown it, or its `usage` (Token Stats' `limits.json` changed, or a live reading moved a window by a point or more). The first change goes out at once, then at most one every 5 seconds, always ending on the latest list. Replaces the list from `hello` |
| `clis.updated` | `{ clis: CliStatus[] }` sent to every connected client when a CLI's status changes (a check finished, an update started, moved on or ended). The latest list wins |
| `schedules.updated` | `{ schedules: Schedule[] }` sent to every connected client whenever any schedule changes (made, edited, run, deleted, or its thread deleted). The whole list, in `schedules.list` order |
| `projects.updated` | `{ projects: Project[] }` sent to every connected client when any project changes, as `projects.list` with `archived: true` would answer. Thread membership changes come as `thread.updated` |
| `librarian.updated` | `{ librarian: LibrarianStatus }` sent to every connected client when the librarian's status changes |
| `settings.updated` | `{ settings: Settings }` sent to every connected client when a setting or the key changes, and at most once a minute while model calls are adding to the spend |
| `runner.notice` | `{ level: "info" \| "warning" \| "error", message }`. Also sent straight after the `hello` result for things the client missed (startup problems, a missing `claude` binary) |
| `runner.updates` | `{ updates: RunnerUpdates }` sent to every connected client when the runner's own update state changes (below). Replaces the one from `hello` |

## Runner updates

`hello` carries `updates?: RunnerUpdates`, and `runner.updates` sends it
again whenever it changes, so a client can show that the runner is
updating itself (docs/dev-tools.md, "The runner updating itself").

```ts
type RunnerUpdates = {
  // The runner following main (runner.status's update.state).
  state: "off" | "idle" | "checking" | "building" | "waiting" | "failed"
  commit?: string       // main's short commit it last saw or is building
  subject?: string      // that commit's subject line
  reason?: string       // off: why; failed: what went wrong
  // Runners that handed over and are still finishing turns (Handovers).
  oldRunners: { version: string; threads: string[] }[]
  // launch.mjs on main differs from the installed one, which only
  // install-runner.sh replaces.
  launcherChanged?: true
}
```

"Pending" for a client means `building`, `waiting`, any `oldRunners`, or
`launcherChanged`; `failed` is worth a look too. `waiting` is brief once
handovers are on: the release is built and the switch starts as soon as
the restart is asked for.

## Restarts

`runner.restart` restarts the runner without cutting a turn short.

- `when: "idle"` (the default) waits until no thread is starting, running or
  waiting on an approval or a question, and no CLI is still running
  background shells or subagents (stopping the runner stops those too).
  Then it shuts down the way it does on SIGTERM and exits 0, and launchd
  starts it again. `waitingFor` names the threads it is waiting for. A
  message sent meanwhile still starts a turn, and the restart waits for
  that turn too. Background work can go on for ever (a dev server, a
  watcher), so `backgroundWaitMs` puts a limit on it: from then on only
  turns hold the restart, and the background work it stops gets the note
  below. A thread deleted meanwhile stops holding it. Turns are never cut
  short by an idle restart. When background
  work ends while a turn is running, the thread stays busy for up to 15 s
  after that turn, since the CLI may start a turn of its own to read the
  result. Once the shutdown has begun, `threads.send` and
  `threads.create` answer `-32020` ("The runner is restarting; send again
  in a moment.").
- `when: "now"` shuts down straight away. Turns in flight end as `stopped`.
  Whenever the runner stops with background work still going, each thread
  that had some gets a `system.note` saying what was stopped.
- While a restart is pending, every client gets a `runner.notice` ("The
  runner will restart when 2 threads finish."), and clients that say hello
  get it again. Threads waiting on an approval or a question won't finish
  until someone answers, so they're counted apart: "The runner will restart
  when 1 thread finishes and you answer 2.", or "when you answer 1 thread."
  The Mac app reads these sentences (the numbers after "when" add up to the
  threads waited for), so they change together. `runner.status` shows it as `pendingRestart`. When it
  starts, the notice is "The runner is restarting now."
- The request is saved in `restart.json` in the data dir, so a crash
  before the runner is idle doesn't lose it: the next start counts as the
  restart. If the runner stops some other way while it waits (launchctl,
  a reboot), that stop counts as the restart. Asking again while one is
  pending merges the two: `now` wins, the earliest background limit
  wins, and each thread's latest `resume` is kept.
- `cancel: true` withdraws it. If it was a deploy's restart onto a release
  that `current` names and this runner isn't running, the runner points
  `current` back at its own release, so the withdrawn release doesn't
  start on the next restart of any kind; `note` says so (or, when it
  can't, that the release is still current).
- `resume` carries a thread on afterwards. On the next start the runner
  adds a `system.note` "Runner restarted: <old version> to <new version>"
  to that thread (with " (from branch X)" for a release not built on main,
  and the rollback notice below as a second paragraph if the new release
  kept crashing), then sends `text` as a new turn whose `user.message` has
  `origin: "runner"`. The text is only sent if the old runner stopped less
  than 15 minutes ago (after a crash, if that thread asked less than 15
  minutes ago), the thread isn't snoozed or archived, nobody has sent it a
  message since it asked, and the runner hasn't already resumed it 3 times
  in the last hour; otherwise there's only the note, saying why. A
  resume sent again after a crash rollback (below) replaces the one the
  crashed release sent, so it doesn't count twice.
- If the request named a `release` and the runner came back on another one
  (it kept crashing, or a later deploy replaced it), the note says so and
  the text sent starts with "Note from the runner: ..." saying which
  release is running, so the agent doesn't take the old code for its own.
- The handled request is kept as `restart.done.json` until the new runner
  has stayed up 60 seconds or stops cleanly. If it crashes before then,
  the same release starting again leaves the file alone (launch.mjs gives
  a broken release a second start), and when launch.mjs then goes back to
  the last good release, that runner resumes the same threads once more,
  with the rollback in the note and the message.
- A runner that had to go back to an earlier release because the new one
  kept crashing at startup says so with a `warning` notice at startup and
  after every `hello` ("Release X kept crashing at startup, so the runner
  went back to Y.").

### Handovers

A runner started by `launch.mjs` as a supervised child
(`THREADBARE_SUPERVISED=1`, docs/dev-tools.md) doesn't make an idle
restart wait for busy threads. It hands over instead:

- If no thread is busy, it restarts as above.
- Otherwise the busy threads (the ones an idle restart would wait for,
  background work included) are *kept*, and `launch.mjs` starts the new
  release beside this one. `runner.restart` answers at once with
  `waitingFor: []` and `handover: { keeps: string[] }`.
- The old runner is now *draining*. It stops listening on the runner's
  port, lets go of every thread it doesn't keep (their idle CLIs exit and
  resume by session id on the new runner), stops its schedules, updates
  and CLI installs, and listens on a port of its own on 127.0.0.1, written
  to `run/drain-<pid>.json` as `{ pid, port, version, release?, since,
  threads: string[] }`. Same token.
- The new runner (the *primary*) reads those files at startup, connects to
  each, and doesn't load the kept threads itself. Clients only ever talk to
  the primary: a request about a kept thread (`threads.send`,
  `threads.events`, `threads.subscribe`, `approvals.respond` and the rest)
  goes to the draining runner and its answer comes back unchanged, and the
  draining runner's `thread.updated`, `thread.event`, `thread.deleted` and
  `runner.notice` come through the primary. `threads.list`,
  `threads.search` and `hello` include kept threads.
- A kept thread moves across once nothing would be cut short: no turn,
  approval or question, background work or wake grace. Background shells
  and monitors hold it for 30 minutes after its last turn at most (a dev
  server never ends), and are then stopped with the usual note. Subagents
  hold it until they finish, up to 4 hours: they end by themselves, and
  stopping one throws its work away. Messages queued for it at that moment move with it
  and the primary starts them, so a message sent during the turn runs on
  the new release. The draining runner saves the thread, then sends the
  primary `drain.handedOver { threadId }`; the primary loads it and carries
  on (the same seqs; a client's subscription keeps going). Once it keeps
  nothing, the draining runner exits.
- A request for a thread the draining runner has already let go answers
  `-32030` ("moved"), and the primary handles it itself.
- The threadbare tools in a kept thread's session reach the primary over
  the runner's port for anything about other threads, and its schedules.
- A `resume` for a kept thread is sent when the thread moves across,
  rather than when the new runner starts, and the 15-minute limit counts
  from then.
- If a draining runner dies, the primary takes its threads as after a
  crash (a turn in flight ends as `stopped`) and stops the process groups
  it left (`run/children-<pid>.json`).
- `runner.status` on the primary lists draining runners as `draining: {
  pid, version, release?, since, threads: string[] }[]`.
- `when: "now"` restarts the primary straight away and tells each draining
  runner to stop too (`drain.stop`).
- Another handover while one is draining makes the primary a draining
  runner as well; draining runners don't hand over again, and close their
  own connections to older ones, which the new primary connects to.

- The primary's summaries of kept threads carry `onOldRunner: true`, so a
  client can say a thread is finishing on the old release. The flag goes
  when the thread comes across.
- Usage readings from kept threads' turns go to the primary
  (`drain.usage { accountId, reading }`), which owns `usage.json`.
- The runner's notice when it hands over starts "The runner is restarting
  onto a new release", which clients already read as a restart under way.

The methods between runners (`drain.hello`, `drain.stop`) and
`drain.handedOver` and `drain.usage` are for runners only.

## Settings and models

The runner makes small model calls of its own (classify, extract,
summarise, generate) for features like titles, digests and needs-you
triage. They go to OpenRouter (`src/models/`), with one key Mike sets in
the Settings window, `tb models key`, or by writing
`secrets/openrouter-key` himself. The app never holds the key: it sends
it once through `settings.setKey` and only ever hears `set` and `hint`.

- **Consent.** Setting a key is the go-ahead to send thread text to
  OpenRouter and the model's provider (ScaleDown, or Google or Amazon
  for Haiku). Every call asks OpenRouter for zero data retention
  (`provider.zdr`), so it only goes to endpoints that keep nothing, with
  no change to the account's own privacy settings. With no key, nothing
  is sent and every feature falls back to what it did before.
- **Private folders.** `models.privateFolders` in `runner.json` lists
  folders whose threads are never sent, for client work and the like. A
  call for a thread in one of them, or anywhere under one, doesn't go out.
- **Budget.** `models.dailyBudgetUsd` (default 1) caps what's spent per
  local day. Once a call takes it over, later calls that day don't go out,
  and every client gets one `warning` notice saying so. 0 stops all calls.
- **Spend.** Each call that goes out adds a line to `models/usage.ndjson`
  in the data dir: `{ ts, feature, job, model, ok, ms, inputTokens?,
  outputTokens?, costUsd?, error? }`, with the cost OpenRouter reports.
  No text from the call is kept. `spentTodayUsd` and `spentMonthUsd` add
  these up.
- **Titles.** A new thread's title is the first line of its first
  message, as before; with a key, a few seconds later a small model's
  title replaces it, unless someone has set one meanwhile. Threads from
  before there was a key keep their first line until `threads.retitle`
  names them too.
- **Failures.** A call never throws: it says why it didn't answer (no key,
  private folder, over budget, timed out, provider error), and the feature
  falls back. Each call times out after 20 seconds, is tried again once
  on a network error, a 5xx or an empty answer (not one cut off by its
  token limit), and at most 4 are in flight at once.

## Patches

A thread's folder can give it panels (shown beside the transcript) and
actions (chips above the composer); see docs/threadbear-design/README.md.
The runner works them out from the folder (`src/patches.ts`), nothing is
stored, and they come in the summary's `panels`, `actions` and `patches`,
so a client learns of them like any other change. The runner reads the
folder again in the background when the folder changes and otherwise
every 15 seconds at most (on the next summary it sends), and sends a new
summary if anything differs, so a `.env.local` that `convex dev` has just
written, or a patch file the agent has just saved, shows up within
seconds. A patch file that appears, loads again or breaks after the first
read is said in the transcript as a `system.note`.

Patches are found by walking up from the thread's folder to the home
folder (so a thread in a package of a monorepo gets the project's), plus
`~/.threadbear/patches/` for every folder, plus every folder of every
project the thread is in (see Projects). Two kinds:

**Patch files**: `.threadbear/patches/<name>.ts` (or `.js`, `.mjs`). The
runner imports the module (Node runs TypeScript as it is; a changed mtime
loads it again) and reads its default export:

```ts
// .threadbear/patches/reseed.ts
export default {
  actions: [
    { title: "Reseed dev DB", run: "npx convex run seed:reset && npx convex import --replace fixtures/dev.zip" },
    { title: "Explain the schema", prompt: "Read convex/schema.ts and explain it to me." },
  ],
  panels: [{ title: "Storybook", url: "http://localhost:6006", note: "while npm run storybook is up" }],
}
```

`run` is a command for `actions.run` to run in the thread's folder,
`prompt` a message it sends instead; one or the other. A panel needs a
`url` with a scheme. A hook is a command the runner runs by itself:

```ts
  hooks: [
    { title: "Typecheck", on: "turn.end", run: "npx tsc --noEmit", edited: "**/*.{ts,tsx}" },
  ],
```

`on: "turn.end"` (the one trigger so far) runs it after each turn the
agent completed, in the thread's folder like an action, and its output
goes into the transcript as an `action.run` with `trigger`. With
`edited`, only after a turn that edited or wrote a file matching that
glob (from `edit.diff` paths and Edit and Write calls). `tell` says when
the result also goes to the agent, as a `user.message` from the runner
(`origin: "runner"`) that starts a turn: `"failures"` (the default) when
the command failed, `"always"`, or `"never"`. The message names the hook
and the patch, carries the last 8 KB of output in a code block, and asks
the agent to fix it if it's theirs. One hook is told at most twice in a
row (a hook that keeps failing is then only posted) and a message from
anyone else starts the count again, so a hook and an agent can't go round
for ever.

Ids are the file's name plus a slug of the title
(`reseed.reseed-dev-db`), and two entries in one file can't share one. A
file whose export doesn't fit is listed in `patches` with an `error` and
gives nothing. Loading a project's module is the same trust as `npm
install` in it.

**Built in**, from the folder alone:

| patch | when | panel |
|---|---|---|
| `convex` | a folder with `convex/` | `convex.dashboard`, a `url` panel: `https://dashboard.convex.dev/d/<name>` for the `CONVEX_DEPLOYMENT` in `.env.local` (then `.env`), `http://127.0.0.1:6790` for an anonymous local deployment, the dashboard's front page with no deployment yet. Only that one line of the file is read |
| `xcode` | a folder with an `.xcodeproj` or `.xcworkspace` | `xcode.simulator`, an `image` panel drawn by `panels.render` |

A client shows what it can: a `url` panel in a web view, an `image` panel
by asking `panels.render` now and then while it's on screen, and an
unknown `kind` as a page if it has a `url`.

## Projects

A project groups threads above folders: it can have several folders, a
thread can be in several projects, and it keeps `goals`, `state` and
`notes` that carry forward from thread to thread. Nobody has to make one:
the librarian and the agents do. Kept in `projects.json` in the data dir;
which projects a thread is in is kept with the thread.

**Patches.** A thread loads patches from, in this order: `~/.threadbear/`,
each folder of each of its projects (the built-in ones and the patch
files found walking up from it, each folder once), then its own folder
as before. Anything from a project folder has `folder` and `projectId`
set and runs in that folder; a hook from one only runs after a turn that
edited a file inside it, matched against its `edited` glob relative to
it. Two items that would share an id get the folder's name in front, the
later one only (`poddle:convex.dashboard`).

**The brief.** A session is told about its thread's projects once each.
A fresh session (a new thread, a move or account change that starts a new
native session) gets the brief as instructions: each project's title,
folders, goals and state, at most about 2,000 characters in all, and that
`read_project` has the notes. Claude gets it appended to the system
prompt, Codex as developer instructions. A live or resumed session (Claude
Code ignores new instructions on a resume) hears about a project it hasn't
been told about at the start of its next message, in a line beginning
`[Threadbear project]`; a session from before projects existed gets the
whole brief that way. An agent that joined a project itself isn't told.

**The librarian** is the runner's own background job that keeps projects
up to date, on the small model (`models.*`, feature `projects`, inside the
daily budget, never for private folders). It looks at a thread when:

- its first turn ends (`first-turn`), 10 seconds later;
- a turn edits files outside its folder and its projects' folders
  (`new-folder`), 10 seconds later;
- it moves folder (`moved`);
- it has had turns since the last look, an hour after that look at the
  soonest (`catch-up`);
- someone asks (`librarian.run`, `asked`).

One look at a time, the soonest due first. A look sends the model the
project list (title, folders, goals, one line of state) and the thread's
title, folder, first message, last few messages and the folders it edited
in, and gets back the projects the thread belongs in, a new project when
none fits, and a new `state` for a project the thread moved on. What it
decides takes effect straight away: the thread gets `projects` (`by:
"librarian"`) and a `system.note` saying so ("Put in Threadbear"), and
Mike can take it out (`threads.setProjects`), after which it's never put
back. It never takes out a pinned project or one an agent added. Looks
are listed in `LibrarianStatus.recent`; without a key or budget the queue
waits (`state: "off"`).

**Agents** have tools for projects (see Tools for agents):
`list_projects`, `read_project`, `create_project`, `update_project`,
`join_project` and `leave_project` (each for their own thread by default).
An agent's join is pinned.

## Schedules

A schedule sends a message at a set time, once (`at`) or over and over
(`cron`), like Convex's scheduled functions and crons. It either sends to
a thread that already exists or starts a new thread each time. They're
kept in `schedules.json` in the data dir.

- **Cron.** Five fields: minute, hour, day of month, month, day of week
  (0 or 7 is Sunday), with `*`, lists (`1,15`), ranges (`1-5`), steps
  (`*/15`, `9-17/2`) and names (`jan`, `mon`). When both day fields are
  restricted, either one matching is enough, as in standard cron. Read in
  `timezone`, or the Mac's own zone. A time that doesn't exist on a
  daylight-saving day runs at the first minute that does; one that happens
  twice runs once.
- **Sending.** The message starts with a line saying which schedule sent
  it, `[Scheduled: "<title>", <whenText>]`, so the agent knows Mike didn't
  just type it, and its `user.message` has `origin: "schedule"` and
  `scheduleId`. A message for a thread that's busy waits for the running
  turn to end (it doesn't go into it), then starts its own turn. A snoozed
  or archived thread comes back to the inbox, as with any message.
- **New threads** get the schedule's title and settings and are made the
  way `threads.create` makes them. A repeating schedule whose last thread is
  still starting, running or waiting on Mike skips that run
  (`lastRun.outcome: "skipped"`) rather than pile up threads.
- **Late runs.** The runner checks at least every 30 seconds, so a Mac
  that was asleep (when timers stop) catches up soon after it wakes. A run
  that was due while the runner was stopped or the Mac slept happens once
  as soon as it can, however many were missed; then `nextRunAt` is the
  next time after now. While the runner is restarting, a due run waits for
  the new one.
- **Failures.** A run that can't send (the folder or account has gone)
  records `lastRun.outcome: "failed"` and a `note`, and a repeating
  schedule carries on next time. Deleting a thread deletes the schedules
  that send to it.
- **Agents** make and change schedules with the `threadbare` tools
  (`schedule_message`, `list_schedules`, `update_schedule`,
  `delete_schedule`); `createdBy` is their thread. By default an agent's
  schedule sends to its own thread ("check the deploy again in 20
  minutes").

## Ordering and reconnects

- Persisted events for a thread are delivered in `seq` order with no gaps.
- After a reconnect, the app calls `threads.subscribe` with the last `seq` it
  has; the runner replays the gap, then streams. `inProgress` in
  `threads.events` lets the app show a partially streamed block it missed.
  Deltas sent between a `threads.events` load and the `threads.subscribe`
  never reach the client, so it takes each streaming item's text from the
  subscribe reply's `inProgress` and appends only deltas that arrive after.
- `thread.updated` is level-triggered: the latest summary wins.
- A client that stops reading may miss transient deltas (the persisted
  event replaces them). One that falls far behind is closed with code 4408
  and should reconnect and replay from its last `seq`.

## Tools for agents

Every CLI the runner starts knows which thread it belongs to, two ways: the
`threadbare` MCP server for the agent itself, and environment variables for
the commands it runs (`tb`, the deploy script). Both name the same thread.

Every session, Claude or Codex, gets an MCP server called `threadbare`
(`runner/src/threadbare-mcp.ts`), bound to its own thread, so an agent can
drive Threadbare itself: `list_threads`, `read_thread`, `list_accounts`,
`create_thread`, `send_message`, `update_thread`, `move_thread`,
`interrupt_thread`, `delete_thread`, `schedule_message`,
`list_schedules`, `update_schedule` and `delete_schedule` (see Schedules),
and `list_projects`, `read_project`, `create_project`, `update_project`,
`join_project` and `leave_project` (see Projects).
`list_accounts` shows each account's provider, note and room left;
`create_thread` and `move_thread` take Codex accounts. They call the same runner methods as
the requests above, so once a restart has begun `create_thread` and
`send_message` get its "send again in a moment" too. Messages an agent sends
to another thread (or as a new thread's first message) start with a line
saying which thread sent them. `delete_thread` always asks for approval,
even in a thread with full access, and no tool can delete, interrupt, snooze
or archive the thread that's calling it; `tb` inside a thread refuses the
same. There's no tool for restarting the runner: that's `runner.restart`.

| Variable | Value |
|---|---|
| `THREADBARE_THREAD_ID` | the id of the thread the CLI belongs to |
| `THREADBARE_HOME` | the runner's data dir, where `tb` looks for a runner (agents may point it at a dev runner) |
| `THREADBARE_RUNNER_HOME` | the runner's data dir too, which agents never change: the scripts' guards against restarting the runner a thread runs on go by it |
| `THREADBARE_RUNNER_VERSION` | the runner's version, as in `hello` |

The runner also puts its own `bin/` (the release's, or the checkout's for a
runner run from source) at the front of `PATH`, so a bare `tb` in a thread
is the `tb` that matches the runner.

## Older and newer clients

Either side may be upgraded first, so each tolerates the other:

- An app older than Codex support reads `provider: "codex"` as a plain
  string, an unknown tool `kind` (`image`) as `other` and `ultra` as text;
  lists Codex models under its fallback heading; and may still send a
  Claude alias for a Codex thread, which the runner corrects (above).
- A newer app talking to an older runner gets `-32601` from `clis.*` and
  leaves the CLI part out, sees no `usage` on accounts and says the numbers
  need a newer runner, and sees no Codex accounts.
