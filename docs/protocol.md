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
| `user.message` | `text`, `images: ImageRef[]` |
| `assistant.text` | `itemId`, `text` (complete markdown for that block) |
| `reasoning` | `itemId`, `text` (summary) |
| `tool.call` | `itemId`, `name` (raw tool name), `kind` (`command` \| `read` \| `edit` \| `write` \| `search` \| `web` \| `mcp` \| `task` \| `todo` \| `other`), `title` (one line, e.g. "npm test" or "Edit src/a.ts"), `input` (object, large strings truncated to 16 KB) |
| `tool.result` | `itemId` (matches the call), `ok`, `text` (truncated to 64 KB), `truncated`, `blobPath?`, `images: ImageRef[]` |
| `edit.diff` | `itemId`, `path`, `hunks: {oldStart, oldLines, newStart, newLines, lines: string[]}[]` (lines start with " ", "-" or "+"); sent after `tool.call` for Edit/MultiEdit/Write when the runner can compute it |
| `approval.requested` | `approvalId`, `itemId?` (absent for a subagent's tools, which have no `tool.call`), `name`, `title`, `input`, `options: ("allow" \| "allowAlways" \| "deny")[]` |
| `question.requested` | `approvalId`, `questions: {question, header?, multiSelect, options: {label, description?}[]}[]` |
| `approval.resolved` | `approvalId`, `decision` (`allow` \| `allowAlways` \| `deny` \| `answered` \| `expired`), `message?` |
| `plan.updated` | `entries: {text, status: "pending" \| "in_progress" \| "completed"}[]` |
| `turn.started` | `turnId`. A turn the agent starts by itself (a background task finished, or a background subagent needs an approval) has no `user.message` before it |
| `turn.completed` | `turnId`, `outcome` (`completed` \| `interrupted` \| `failed`), `durationMs`, `costUsd?`, `usage?`, `error?` |
| `system.note` | `text` (e.g. "Resumed session", "Compacted the conversation") |
| `error` | `message` |

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
| `hello` | `{ client: string, version: string }` | `{ runnerVersion, protocol: 1, accounts: Account[], defaults: { cwd, accountId } }` |
| `threads.list` | `{ include?: ("inbox" \| "snoozed" \| "archived")[] }` (default `["inbox"]`) | `{ threads: ThreadSummary[] }` newest activity first |
| `threads.search` | `{ query: string, limit?: number }` | `{ threads: ThreadSummary[] }` matches title and preview across all threads, archived included |
| `threads.create` | `{ text: string, images?: ImageRef[], cwd?: string, accountId?: string, model?: string, permissionMode?: "full" \| "ask", title?: string }` | `{ thread: ThreadSummary }` (the first turn starts straight away) |
| `threads.send` | `{ threadId, text, images?: ImageRef[] }` | `{ turnId }`. If a turn is running, the message is queued and sent when it ends |
| `threads.interrupt` | `{ threadId }` | `{}` |
| `threads.update` | `{ threadId, title?, cwd?, accountId?, model?: string \| null, permissionMode?, snoozedUntil?: string \| null, archived?: boolean }` | `{ thread: ThreadSummary }`. Snoozing or archiving releases the CLI. Changing account or cwd takes effect on the next turn. A folder change on the same account copies the native session's transcript to the new folder and resumes it; otherwise (or if that fails) it starts a new native session with a short handoff note |
| `threads.delete` | `{ threadId }` | `{}`. Stops the thread's CLI and moves its folder to `trash/` in the data dir. Every client gets `thread.deleted` |
| `threads.events` | `{ threadId, afterSeq?: number, beforeSeq?: number, limit?: number }` (default: the newest 500) | `{ events: Event[], firstSeq, lastSeq, inProgress: { itemId, type: "assistant.text" \| "reasoning", text }[] }` |
| `threads.subscribe` | `{ threadId, afterSeq?: number }` | `{ events: Event[], inProgress: { itemId, type, text }[] }` (everything after `afterSeq`, and the text streamed so far for items still streaming), then pushes `thread.event` notifications. Deltas pushed after the reply carry on from `inProgress` |
| `threads.unsubscribe` | `{ threadId }` | `{}` |
| `threads.markSeen` | `{ threadId, seq }` | `{ thread: ThreadSummary }` |
| `approvals.respond` | `{ threadId, approvalId, decision: "allow" \| "allowAlways" \| "deny" \| "answered", message?: string, answers?: Record<string, string> }` | `{}`. `allowAlways` allows matching requests for the rest of this thread only; it never changes the thread's permission mode or saves anything in the project |
| `media.import` | `{ path: string }` | `{ image: ImageRef }` copies a file into `inbox/` and reads its size |

Errors use JSON-RPC error objects: `-32602` bad params, `-32004` thread not
found, `-32010` account not found, `-32020` busy (e.g. two sends racing),
`-32000` anything else with a readable `message`.

## Notifications (runner to app)

| method | params |
|---|---|
| `thread.updated` | `{ thread: ThreadSummary }` sent to every connected client whenever a summary changes |
| `thread.event` | `{ threadId, event: Event }` only for subscribed threads, persisted and transient |
| `thread.deleted` | `{ threadId }` sent to every connected client when a thread is deleted |
| `runner.notice` | `{ level: "info" \| "warning" \| "error", message }`. Also sent straight after the `hello` result for things the client missed (startup problems, a missing `claude` binary) |

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

Every Claude session the runner starts gets an in-process MCP server called
`threadbare` (`runner/src/threadbare-mcp.ts`), bound to its own thread, so
an agent can drive Threadbare itself: `list_threads`, `read_thread`,
`list_accounts`, `create_thread`, `send_message`, `update_thread`,
`move_thread`, `interrupt_thread` and `delete_thread`. They call the same
runner methods as the requests above. Messages an agent sends to another
thread (or as a new thread's first message) start with a line saying which
thread sent them. `delete_thread` always asks for approval, even in a thread
with full access, and no tool can delete, interrupt, snooze or archive the
thread that's calling it.
