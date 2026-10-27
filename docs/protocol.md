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
type Account = {
  id: string            // "claude-main", "claude-1", ...
  provider: "claude"    // "codex" later
  title: string         // e.g. "you@example.com"
  configDir: string
  defaultModel?: string // full id of the model a thread with no model runs on
                        // ("claude-fable-5-1"): the account's own setting,
                        // corrected by the first turn the runner sees. Absent
                        // until the runner knows
  models?: ModelChoice[] // what the account's CLI offers, in its own order,
                        // once the runner has asked it (a few seconds after
                        // it starts)
}

type EffortLevel = "low" | "medium" | "high" | "xhigh" | "max"

type ModelChoice = {
  id: string            // what to send as `model` ("opus", "claude-fable-5-1[1m]")
  model: string         // the full id it runs as ("claude-opus-5-5")
  title: string         // "Opus 5.5"
  description?: string
  effortLevels?: EffortLevel[] // absent when the model takes no effort level
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
  provider: "claude"
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
  archivedAt?: string
  preview: string       // last assistant text, one line, <= 140 chars
  lastSeq: number       // seq of the newest persisted event
  lastSeenSeq: number
  nativeSessionId?: string
  contextTokens?: number
  costUsd?: number      // total for the thread so far, if known
  panels?: Panel[]      // from the folder's patches (see Patches); absent when there are none
  actions?: Action[]    // likewise
  patches?: PatchInfo[] // the patches that apply to the folder; absent when there are none
}

type Action = {
  id: string            // "<patch>.<slug of the title>": "reseed.reseed-dev-db"
  title: string
  kind: "command" | "prompt"
  command?: string      // kind "command": run in the thread's folder by `actions.run`
  prompt?: string       // kind "prompt": sent to the thread as a message by `actions.run`
  patch: string
  note?: string
}

type PatchInfo = {
  id: string            // "convex", "xcode", or a patch file's name without its extension
  source: "builtin" | "home" | "project"
  file?: string         // the module, for home and project patches
  error?: string        // the file couldn't be loaded, and gives nothing until it's fixed
}

type Panel = {
  id: string            // unique within the thread: "convex.dashboard", "xcode.simulator"
  title: string         // the tab's label
  kind: "url" | "image" // a page in a web view, or a picture the runner draws on request
  url?: string          // kind "url": the page; also what Open in browser opens
  patch: string         // the patch it came from: "convex", "xcode"
  note?: string         // one line about it: the deployment, the project
}

type ImageRef = {
  path: string          // absolute path on this Mac
  mediaType: string     // "image/png", "image/jpeg", "image/gif", "image/webp"
  width?: number
  height?: number
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
| `user.message` | `text`, `images: ImageRef[]`, `origin?: "runner"` (set when the runner sent the message by itself, such as the resume after a restart; absent for anything a person or client sent) |
| `assistant.text` | `itemId`, `text` (complete markdown for that block) |
| `reasoning` | `itemId`, `text` (summary) |
| `tool.call` | `itemId`, `name` (raw tool name), `kind` (`command` \| `read` \| `edit` \| `write` \| `search` \| `web` \| `mcp` \| `task` \| `todo` \| `other`), `title` (one line, e.g. "npm test" or "Edit src/a.ts"), `input` (object, large strings truncated to 16 KB) |
| `tool.result` | `itemId` (matches the call), `ok`, `text` (truncated to 64 KB), `truncated`, `blobPath?`, `images: ImageRef[]` |
| `edit.diff` | `itemId`, `path`, `hunks: {oldStart, oldLines, newStart, newLines, lines: string[]}[]` (lines start with " ", "-" or "+"); sent after `tool.call` for Edit/MultiEdit/Write when the runner can compute it |
| `approval.requested` | `approvalId`, `itemId?` (absent for a subagent's tools, which have no `tool.call`), `name`, `title`, `input`, `options: ("allow" \| "allowAlways" \| "deny")[]` |
| `question.requested` | `approvalId`, `questions: {question, header?, multiSelect, options: {label, description?}[]}[]` |
| `approval.resolved` | `approvalId`, `decision` (`allow` \| `allowAlways` \| `deny` \| `answered` \| `expired`), `message?` |
| `plan.updated` | `entries: {text, status: "pending" \| "in_progress" \| "completed"}[]` |
| `turn.started` | `turnId`. A turn the agent starts by itself (a background task finished, or a background subagent needs an approval) has no `user.message` before it. A `user.message` after `turn.started` was sent while the turn ran and went into it |
| `turn.completed` | `turnId`, `outcome` (`completed` \| `interrupted` \| `failed`), `durationMs`, `costUsd?`, `usage?`, `error?` |
| `system.note` | `text` (e.g. "Resumed session", "Compacted the conversation", "Patch reseed added: action Reseed dev DB.") |
| `error` | `message` |
| `action.run` | `actionId`, `patch`, `title`, `command`, `ok`, `exitCode?`, `text` (what it printed, truncated to 64 KB), `truncated`, `durationMs`. A command action that `actions.run` ran; outside any turn unless one was running, in which case it carries that `turnId` |

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
| `hello` | `{ client: string, version: string }` | `{ runnerVersion, protocol: 1, accounts: Account[], defaults: { cwd, accountId, model? } }`. `defaults.model` is the model a new thread gets when it names none (`runner.json`'s `defaults.model`; a dev runner sets the cheapest); absent means the account's own default (`accounts[].defaultModel` names it, when known). `runnerVersion` is `<package version>+<release id>` when the runner runs from a release, else `<package version>+source` |
| `threads.list` | `{ include?: ("inbox" \| "snoozed" \| "archived")[] }` (default `["inbox"]`) | `{ threads: ThreadSummary[] }` newest activity first |
| `threads.search` | `{ query: string, limit?: number }` | `{ threads: ThreadSummary[] }` matches title and preview across all threads, archived included |
| `threads.create` | `{ text: string, images?: ImageRef[], cwd?: string, accountId?: string, model?: string, effort?: EffortLevel, permissionMode?: "full" \| "ask", title?: string }` | `{ thread: ThreadSummary }` (the first turn starts straight away). With no `model`, the thread gets `defaults.model` from `hello` if there is one. With no `effort`, the model's own level |
| `threads.send` | `{ threadId, text, images?: ImageRef[] }` | `{ turnId }`. If a turn is running and its CLI is live, the message goes into that turn straight away (a `user.message` under the running `turnId`, which is returned): the agent takes it at its next step, or right after its reply if that was already finishing, and the turn doesn't complete until it has been answered. Otherwise (the CLI is still starting or leaving, messages are already waiting, a move or fresh CLI is due on the next turn, Stop has been pressed, or the turn is only an approval for a background subagent) the message is queued and starts its own turn when the running one ends |
| `threads.interrupt` | `{ threadId }` | `{}` |
| `threads.update` | `{ threadId, title?, cwd?, accountId?, model?: string \| null, effort?: EffortLevel \| null, permissionMode?, snoozedUntil?: string \| null, archived?: boolean }` | `{ thread: ThreadSummary }`. Snoozing or archiving releases the CLI. Changing account or cwd takes effect on the next turn. A model or effort change reaches a live CLI straight away (`null` goes back to the default). A folder change on the same account copies the native session's transcript to the new folder and resumes it; otherwise (or if that fails) it starts a new native session with a short handoff note |
| `threads.delete` | `{ threadId }` | `{}`. Stops the thread's CLI and moves its folder to `trash/` in the data dir. Every client gets `thread.deleted` |
| `threads.events` | `{ threadId, afterSeq?: number, beforeSeq?: number, limit?: number }` (default: the newest 500) | `{ events: Event[], firstSeq, lastSeq, inProgress: { itemId, type: "assistant.text" \| "reasoning", text }[] }` |
| `threads.subscribe` | `{ threadId, afterSeq?: number }` | `{ events: Event[], inProgress: { itemId, type, text }[] }` (everything after `afterSeq`, and the text streamed so far for items still streaming), then pushes `thread.event` notifications. Deltas pushed after the reply carry on from `inProgress` |
| `threads.unsubscribe` | `{ threadId }` | `{}` |
| `threads.markSeen` | `{ threadId, seq }` | `{ thread: ThreadSummary }` |
| `approvals.respond` | `{ threadId, approvalId, decision: "allow" \| "allowAlways" \| "deny" \| "answered", message?: string, answers?: Record<string, string> }` | `{}`. `allowAlways` allows matching requests for the rest of this thread only; it never changes the thread's permission mode or saves anything in the project. With `answered`, the app sends the chosen answers in one line as `message` too: the runner keeps it in `approval.resolved` (only `answers` goes to the CLI), so the transcript can show what was chosen |
| `media.import` | `{ path: string }` | `{ image: ImageRef }` copies a file into `inbox/` and reads its size |
| `actions.run` | `{ threadId, actionId }` | For a prompt action, `{ turnId }`: its prompt was sent as a message (as `threads.send`). For a command action, `{ ok, exitCode?, durationMs, seq }` once the command has finished, with its output in the transcript as the `action.run` event at `seq`. The command runs in the thread's folder through a login shell with the thread's variables (`THREADBARE_THREAD_ID` and the rest) and is stopped after 10 minutes. `-32602` for an action the thread doesn't have, `-32020` while the same action is still running |
| `panels.render` | `{ threadId, panelId }` | `{ image?: ImageRef, note?: string }` draws an `image` panel now: for `xcode.simulator`, a screenshot of the booted simulator (`xcrun simctl io booted screenshot`), written to the same file each time under the thread's `panels/`. With no device booted (or another failure) there's only `note`. Slow: it waits for the screenshot. `-32602` for a panel the thread doesn't have |
| `runner.status` | `{}` | `{ version, release?, branch?, pid, startedAt, home, logFile, liveClis, running: string[], background: { threadId, tasks: string[] }[], pendingRestart?: { when, reason?, release?, resumeThreadId?, requestedAt, backgroundUntil?, waitingFor: string[] }, rolledBack?: { from, at }, update?: { state, checkout?, reason?, checkedAt?, commit?, release?, logFile? } }`. `running` lists the threads that are starting, running or waiting on an approval or a question; `background` the threads whose CLI is still running background shells or subagents (`tasks` describes each). A restart waits for both. `branch` is the branch the release was built from. `rolledBack` is set when this release is running because `launch.mjs` went back to it from `from`, which kept crashing at startup (and nobody has activated it on purpose since). `update` is the runner following main by itself (docs/dev-tools.md): `state` is `off` (`reason` says why), `idle`, `checking`, `building`, `waiting` (`release` is built and starts on the pending restart) or `failed` (`reason` is the error; `logFile` has the build's output); `commit` is main's tip at the last check (`checkedAt`) |
| `runner.restart` | `{ when?: "idle" \| "now", resume?: { threadId, text }, reason?: string, release?: string, backgroundWaitMs?: number, cancel?: boolean }` | `{ scheduled: boolean, waitingFor: string[], background?: { threadId, tasks: string[] }[], note?: string, noResume?: string }`. See Restarts below. `scheduled` is true once the restart is saved; an empty `waitingFor` means it is happening now. `background` is the background work among `waitingFor`. `release` is the release the restart should come back on (the deploy script sets it). `backgroundWaitMs` limits how long background shells and subagents hold the restart. `cancel: true` withdraws a pending restart that hasn't begun and returns `scheduled: false` (`-32020` once it has begun), with a `note` when it also put `current` back. `noResume` says why the `resume` won't be sent as things stand (the thread has already been resumed 3 times in the last hour), so whoever asked can say so rather than wait for it. A runner older than this answers `-32601` |

Errors use JSON-RPC error objects: `-32602` bad params, `-32004` thread not
found, `-32010` account not found, `-32020` busy (e.g. two sends racing),
`-32000` anything else with a readable `message`.

## Notifications (runner to app)

| method | params |
|---|---|
| `thread.updated` | `{ thread: ThreadSummary }` sent to every connected client whenever a summary changes |
| `thread.event` | `{ threadId, event: Event }` only for subscribed threads, persisted and transient |
| `thread.deleted` | `{ threadId }` sent to every connected client when a thread is deleted |
| `accounts.updated` | `{ accounts: Account[] }` sent to every connected client when what the runner knows about an account changes: its `models` once the CLI has been asked, or its `defaultModel` once a turn has shown it. Replaces the list from `hello` |
| `runner.notice` | `{ level: "info" \| "warning" \| "error", message }`. Also sent straight after the `hello` result for things the client missed (startup problems, a missing `claude` binary) |

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
`~/.threadbear/patches/` for every folder. Two kinds:

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
`url` with a scheme. Ids are the file's name plus a slug of the title
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

Every Claude session gets an in-process MCP server called `threadbare`
(`runner/src/threadbare-mcp.ts`), bound to its own thread, so an agent can
drive Threadbare itself: `list_threads`, `read_thread`, `list_accounts`,
`create_thread`, `send_message`, `update_thread`, `move_thread`,
`interrupt_thread` and `delete_thread`. They call the same runner methods as
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
