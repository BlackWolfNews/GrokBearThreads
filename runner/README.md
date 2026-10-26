# Threadbare runner

A small daemon that owns every agent process for Threadbare. It drives the
official Claude Code CLI through `@anthropic-ai/claude-agent-sdk`, keeps
threads on disk, turns SDK messages into the events in
[`docs/protocol.md`](../docs/protocol.md), and serves them to the Mac app
over a local WebSocket JSON-RPC API. Quitting or updating the app never
stops a turn.

TypeScript on Node 24, run directly (Node strips the types, so there's no
build step). Runtime packages: the Agent SDK (pinned to 0.3.310) and `ws`.
No `node:sqlite`; it truncates text at NUL on Node 24, and plain files are
enough.

## Run it

```sh
cd runner
npm ci
npm start                      # listens on 127.0.0.1:8797, path /rpc
```

As a LaunchAgent (`com.mikerosoft.threadbare.runner`, starts at login,
restarted if it exits):

```sh
scripts/install-runner.sh --print       # show the plist, change nothing
scripts/install-runner.sh               # install and start it
scripts/install-runner.sh --uninstall   # stop it and remove the plist
launchctl kickstart -k gui/$(id -u)/com.mikerosoft.threadbare.runner   # restart
```

The plist pins the Node binary (`~/.nvm/versions/node/v24.22.1/bin/node`
by default; change it with `--node` or `THREADBARE_NODE`) and the PATH your
login shell has, so agents can run the same commands a terminal can. Pass
`--path` to set it yourself. Logs go to `~/Library/Logs/threadbare-runner.log`.

## Configuration

`runner.json` in the data dir:

```json
{
  "port": 8797,
  "defaults": { "cwd": "~/dev/me/misc", "accountId": "claude-3" },
  "claudePath": "~/.local/bin/claude",
  "idleMinutes": 30,
  "maxLiveCLIs": 6
}
```

The runner writes `port` (the one it is actually listening on, so the app
can find it) and `defaults.cwd` on start, and `defaults.accountId` whenever
a thread is created on, or moved to, an account, so new threads start on
the last one used.

Environment variables, mainly for tests:

| Variable | What it does |
|---|---|
| `THREADBARE_HOME` | Data dir (default `~/Library/Application Support/Threadbare`). `THREADBARE_DATA_DIR`, the app's name for it, works too. |
| `THREADBARE_PORT` | Port to listen on. `0` picks a free one; it's written to `runner.json`. |
| `THREADBARE_LOG` | Log file (default `~/Library/Logs/threadbare-runner.log`). |
| `THREADBARE_IDLE_MS` | Idle release delay in ms (default 30 minutes). |
| `THREADBARE_MAX_LIVE` | Most CLIs kept live at once (default 6, or `maxLiveCLIs` in `runner.json`). |
| `THREADBARE_CLAUDE_PATH` | The `claude` binary (default `~/.local/bin/claude`, so the CLI keeps updating itself). |
| `THREADBARE_ACCOUNTS_DIR` | Where `claude-N` logins live (default Token Stats' `Accounts` folder). |
| `THREADBARE_CLAUDE_MAIN_DIR`, `THREADBARE_CLAUDE_MAIN_JSON` | The main login (default `~/.claude` and `~/.claude.json`). |
| `THREADBARE_DEBUG=1` | Log CLI stderr and other detail. |
| `THREADBARE_LOG_STDERR=1` | Also print the log to stderr. |

## Data layout

```
~/Library/Application Support/Threadbare/
  runner.json
  secrets/runner-token          random bearer token, 0600 (folder 0700)
  inbox/                        images the app imports before sending
  run/children.json             CLI process groups this runner started, and the
                                groups their tool commands ran in
  run/runner.pid                the lock: pid and start time of the runner that
                                owns this data dir
  threads/<threadId>/
    thread.json                 summary plus internal state, written atomically
    events.ndjson               persisted events, line N is seq N
    media/                      images sent with messages or returned by tools
    blobs/                      full tool output when it's over 64 KB
```

`events.ndjson` is append-only. On load the runner indexes line offsets so
a page of a long thread is one read; a half-written last line from a crash
is dropped so `seq` stays gapless. A `thread.json` that can't be read is
moved aside (`thread.json.unreadable-<time>`) and rebuilt from the event log:
title, preview and seqs come back, while the folder, account and permission
mode reset to the defaults and `ask`, and the next message starts a new
session with a handoff note. Temp files from interrupted atomic writes are
removed at startup.

## The tb CLI

`bin/tb` talks to a running runner. It reads `THREADBARE_HOME` and the port
from `runner.json` like the runner does (`THREADBARE_PORT` or
`THREADBARE_URL` override it). Thread ids can be shortened to a unique
prefix.

```sh
bin/tb new "Fix the flaky test" [--cwd DIR] [--account claude-3] [--model M] [--ask] [--image FILE] [--wait]
bin/tb send <id> "and commit it" [--image FILE] [--wait]
bin/tb list [--snoozed | --archived | --all] [--json]
bin/tb search "words"
bin/tb tail <id> [--from SEQ] [--json] [--until-done]
bin/tb events <id> [--json]
bin/tb interrupt <id>
bin/tb approve <id> <approvalId> [allow|allowAlways|deny]
bin/tb answer <id> <approvalId> "Tea"
bin/tb snooze <id> 2h          # or an ISO time
bin/tb archive <id>            bin/tb unarchive <id>
bin/tb accounts
```

## How it behaves

- **Accounts.** `~/.claude` is `claude-main`; each Token Stats
  `Accounts/claude-N` folder is `claude-N`. The title is
  `oauthAccount.emailAddress` from that login's `.claude.json`, and nothing
  else is read from it. Tokens stay in the Keychain. The CLI gets
  `CLAUDE_CONFIG_DIR` for `claude-N` logins and has it removed for
  `claude-main`.
- **One runner per data dir.** `run/runner.pid` is taken with an exclusive
  create before anything else happens. A second runner (say `npm start`
  while the LaunchAgent runs) exits with "Another runner (pid N) is already
  using ..." without sweeping or recovering anything. A lock whose owner has
  exited, or whose pid now belongs to a process that started at another
  time, is taken over. A port that's in use is reported the same way.
- **One `query()` per live thread** in streaming-input mode. New threads get
  a pre-assigned session id; later starts use `resume`. Two live CLIs never
  share a session: a new one waits for a releasing one to exit.
- **Idle release.** 30 minutes after a turn ends with nothing pending, or
  straight away on snooze or archive, the runner ends the CLI's input so it
  exits. The next message resumes the session and adds a "Resumed session"
  note. Snoozing or archiving mid-turn interrupts the turn first. A CLI
  with background work (a `run_in_background` shell, an async subagent) is
  not released at the idle time; the countdown starts when the work ends.
  Snoozing, archiving or moving a thread with background work stops the CLI
  at once rather than waiting for it, and a system note lists what was
  stopped.
- **Live CLI cap.** Each live CLI is a `claude` process plus its own copy of
  the account's MCP servers, about 400 MB on these logins. When starting
  one would pass `maxLiveCLIs` (default 6), the one idle the longest is
  released first. CLIs with a turn, an approval, queued messages or
  background work are never picked; if every one is busy the cap is passed
  rather than stopping work.
- **Turns the CLI starts by itself.** When a background shell or async
  subagent finishes, the CLI runs a turn on its own. The runner gives it a
  turn in the thread: `turn.started` with no `user.message`, a system note
  with the CLI's summary of what finished, the output, then
  `turn.completed`, so the thread shows running and `needsYou` is raised
  when it ends. A message sent meanwhile is queued behind it. Each message
  the runner sends carries its turnId as the SDK message uuid; the CLI's
  `command_lifecycle` frames then say which turn answers which message, so
  a CLI turn that started just before a send never ends that send's turn.
  A subagent that asks for approval after the turn that started it has
  ended gets a turn the same way, and the card is shown.
- **Permission modes.** `full` runs the CLI with `bypassPermissions`. `ask`
  uses `default` mode and turns `canUseTool` into `approval.requested`; for
  Edit, MultiEdit and Write the `edit.diff` comes first, computed from the
  file as it is. `AskUserQuestion` always becomes `question.requested`, in
  both modes. Switching mode or model mid-session goes to the live CLI.
  A subagent's tool requests have no `itemId` (its tool calls aren't in the
  thread) and no diff.
- **Always allow** applies to the thread. The CLI's suggested allow rules
  (for example `Bash(touch second.txt)`) are applied to the live session
  only, kept in `thread.json`, and passed back as `allowedTools` whenever
  the thread's CLI starts again, so they outlast idle release and restarts.
  Suggestions that would switch the session's permission mode (to
  `acceptEdits`) or save rules in the project's `.claude/settings.local.json`
  are dropped; when only a mode switch was offered, the tool itself is
  allowed for the thread.
- **Interrupt.** If the CLI hasn't ended an interrupted turn after 10
  seconds, the runner ends it as `interrupted` anyway.
- **Queued sends.** A message sent during a turn is queued and starts when
  the turn ends. A snoozed or archived thread keeps its queue until it's back.
- **Folder or account change.** Takes effect on the next turn as a fresh
  native session. The new session's first message carries a short handoff
  note with recent messages; the transcript shows only what was typed, plus
  a system note.
- **Deltas** are coalesced to at most about 30 a second per thread, carry the
  seq of the last persisted event, and are never persisted.
  `threads.events` and `threads.subscribe` return `inProgress` with the text
  streamed so far; a client takes the subscribe reply's as the base for the
  deltas that follow, since deltas sent before it subscribed never reach it.
  `tool.output.delta` is never sent for Claude: the SDK reports nothing from
  a running command but elapsed time (`tool_progress`).
- **Images.** Images sent with a message are copied into the thread's
  `media/` (so cleaning `inbox/` never breaks a transcript) and sent to the
  model as base64; ones over about 3.7 MB or 7900 px are shrunk with `sips`
  first. Images in tool results are saved to `media/` with their pixel size.
  Only regular files up to 100 MB are accepted, so a named pipe can't block
  the runner.
- **Big tool output.** Over 64 KB, `tool.result` text is cut (at a
  character boundary) and the whole text saved to `blobs/`. The CLI itself
  saves Bash output over about 30 KB to a file in the account's folder and
  gives the model a 2 KB preview; the runner copies that file into `blobs/`
  and points `blobPath` at the copy.
- **Stopping and startup recovery.** When the runner stops cleanly, turns in
  flight end there and then: streamed text is kept, pending approvals
  expire, and the turn ends `interrupted` with the thread `stopped`. If it
  was killed instead, the next start does the same for threads it finds
  mid-turn (unless the turn's `turn.completed` reached the log before the
  crash, when only the status is put right). Either way, queued messages
  that never ran are kept in a system note, and the next message resumes
  the session.
- **Notices.** `runner.notice` goes to every client. Notices from startup
  (threads stopped mid-turn, leftover processes stopped) are also sent to
  any client that says `hello` in the next 10 minutes, and a missing
  `claude` binary is reported after every `hello`.
- **Clients.** A socket that hasn't authenticated within 5 seconds, or
  sends a binary frame first, is closed with 4401. A client that stops
  reading has deltas skipped once 1 MB is waiting for it, and is closed
  with 4408 past 32 MB; it reconnects and replays from its last seq.
- **Process groups.** Each CLI is spawned in its own process group and
  recorded in `run/children.json` with its start time. The CLI runs each
  Bash command in a group of its own, so every 5 seconds while CLIs are
  live the runner also records the groups their descendants are in. (Tagging
  them through the environment doesn't work: `ps -E` shows no environment
  for other processes on this macOS.) On SIGTERM, SIGINT or SIGHUP the
  runner stops every group (SIGTERM, then SIGKILL after 3 s). A CLI that
  exits with anything but 0 has the groups its tool commands ran in stopped
  too. If the runner is killed outright, the next start stops the groups it
  left and waits until they're gone before it loads threads or listens, so
  a resume never runs beside the old CLI. A group is only touched if its
  leader started at the recorded time, or its leader has exited and the
  group lives on, so a recycled pid (a terminal's `claude`, say) is never
  hit.
- **Disk errors.** A send whose events can't be written fails with the
  error and leaves the thread as it was. A queued message that can't start
  stays at the front of the queue, and output that can't be saved is
  reported as a `runner.notice` rather than looking like a CLI crash.
- **needsYou** is true while waiting on an approval or question, after a
  turn finishes past `lastSeenSeq`, and when a snooze ends.

## Code map

| File | What it holds |
|---|---|
| `src/main.ts` | Entry point: config, logger, orphan sweep, runner, server, signals. |
| `src/runner.ts` | Threads, turns, queue, approvals, idle release, snooze, events, summaries. |
| `src/rpc.ts` | WebSocket JSON-RPC server, auth, subscriptions. |
| `src/adapters/types.ts` | The adapter interface. Codex will be a second implementation. |
| `src/adapters/claude/adapter.ts` | Claude Agent SDK session: options, input queue, `canUseTool`, interrupt, release. |
| `src/adapters/claude/normalize.ts` | SDK messages to protocol events. Pure; tested with recorded sequences. |
| `src/tools.ts`, `src/diff.ts` | Tool kinds and titles, input truncation, edit diffs, plan tracking. |
| `src/store.ts` | `thread.json` and `events.ndjson`. |
| `src/proc.ts` | Process groups, tool command groups and orphan cleanup. |
| `src/lock.ts` | The one-runner-per-data-dir lock. |
| `src/accounts.ts`, `src/media.ts`, `src/config.ts` | Login discovery, image handling, config and data dir. |
| `src/cli.ts`, `src/client.ts` | `tb` and the small client it and the tests use. |

## Tests

```sh
npm test            # unit tests, no network, about 5 seconds
npm run typecheck
npm run test:e2e    # real Claude CLI, about 2.5 minutes
```

The unit tests cover normalisation (recorded SDK sequences in
`test/fixtures/`), persistence, seq and replay, idle release and snooze with
a fake clock, approvals, queueing, handoff, recovery, CLI-started turns,
background work, the live CLI cap, disk errors, the RPC server (auth
timeout, backpressure), process groups and the lock (with real processes),
two runners starting on one data dir, and `tb`.
`test/helpers/protocol-check.ts` checks events and summaries against
`docs/protocol.md` and is shared by both suites.

The end-to-end suite starts the runner on a free port with a temp data dir
and drives account `claude-3` on `claude-haiku-5-5` in a temp folder:
streaming, a Read tool call, resume after idle release, interrupt, an
ask-mode Write approval, AskUserQuestion, an image in and an image out, a
folder change handoff, `tb`, archive, a background shell whose finish
starts a turn (with a send queued behind it), snoozing with a background
job, "Always allow" across a resume, an edit to a file with no final
newline plus big Bash output, a background subagent's approval, a SIGKILLed
runner and a clean stop.
`TB_E2E_ACCOUNT` and `TB_E2E_MODEL` change the account and model;
`TB_E2E_KEEP=1` keeps the temp folder for a look afterwards.

To record a new fixture, run a throwaway `query()` script that writes every
SDK message as a line to a file in `.fixtures/` (gitignored; raw recordings
are private), then sanitise it:

```sh
node scripts/sanitize-recording.ts .fixtures/rec.ndjson test/fixtures/name.ndjson /abs/folder/it/ran/in
```

## SDK quirks we hit (0.3.310, CLI 2.1.310)

- **`canUseTool` in bypass mode.** The SDK warns
  `CLAUDE_SDK_CAN_USE_TOOL_SHADOWED` ("canUseTool will not be invoked") when
  both are set, but `AskUserQuestion` still goes through `canUseTool`. The
  runner relies on that and hides the warning.
- **`canUseTool` can beat the tool call.** It is sometimes called before the
  assistant frame carrying that `tool_use` comes out of the message
  iterator. The adapter waits up to 2 s for the frame so events stay in the
  order `tool.call`, `edit.diff`, `approval.requested`.
- **One assistant frame per content block.** With partial messages on, the
  CLI sends a separate `assistant` message for each finished block, all with
  the same message id. The Nth frame for an id is stream index N, which is
  how item ids (`<messageId>:<index>`) line up with deltas.
- **Late deltas.** A complete frame can arrive before its last
  `content_block_delta`; deltas for a finished item are dropped.
- **Interrupt.** `query.interrupt()` returns `{ still_queued: [] }`. The turn
  ends with a `result` of subtype `error_during_execution`, `is_error: true`,
  `terminal_reason: "aborted_streaming"` (or `"aborted_tools"`), an `errors`
  list of `[ede_diagnostic] ...` lines, and no complete frame for the text
  that was cut off. The runner keeps the streamed text and reports
  `interrupted`, not `failed`. Before the CLI has started, `interrupt()`
  throws; the runner kills the CLI instead.
- **Cost is a running total.** `total_cost_usd` counts the whole native
  session and carries on across `resume`, so a turn's cost is the
  difference from the previous result.
- **Resume needs a transcript.** If a CLI dies before writing its first
  message, `resume` fails with "No conversation found". The runner starts a
  fresh session once and resends the message.
- **Inherited session variables.** Started from inside a Claude Code session
  (a terminal in T3, these tests), the CLI would see `CLAUDECODE`,
  `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID` and friends and think
  it was nested. The adapter removes them.
- **Mode switching.** `setPermissionMode('bypassPermissions')` only works if
  the session started with `allowDangerouslySkipPermissions`, so every
  session sets it, which lets "Ask before edits" be turned off mid-thread.
- **Message origin.** User messages without `origin` count as unattributed
  and fail closed at the CLI's `isHuman()` checks; the adapter stamps
  `{ kind: "human" }`.
- **Resolved paths.** Tool results report real paths (`/private/tmp/...`,
  `/private/var/folders/...`) even when the thread's folder was given
  through a symlink, so titles try both forms when making paths relative.
- **Write diffs.** A Write that creates a file has an empty
  `structuredPatch`; the diff is rebuilt from the content. Edit results
  carry a usable `structuredPatch`.
- **Images from Read.** Reading an image returns a base64 `image` block in
  the `tool_result` content, which is saved to `media/`.
- **Cost of interrupted turns.** The `result` for an interrupted turn
  usually leaves `total_cost_usd` where it was, so those turns show a cost
  of 0.
- **stderr noise.** Every start prints "claude.ai MCP server blocked by
  enterprise policy" on these logins; it's left out of error messages.
- **Turns the CLI starts itself.** After a `run_in_background` shell or an
  async subagent (the Agent tool is async by default) finishes while
  nothing is running, the CLI sends `system/task_notification` (with a
  `summary`), then `system/init` and a whole turn ending in a `result`,
  with nothing sent to it. Mid-turn the notification is folded into the
  running turn instead. `background_tasks_changed` gives the full list of
  running tasks each time it changes. `session_state_changed` is not sent
  by default.
- **Message uuids and `command_lifecycle`.** A user message sent with a
  `uuid` gets `command_lifecycle` frames (`queued`, `started`, `completed`,
  with `command_uuid`; not in the SDK's types), and the turn's first
  assistant frame and stream event carry `user_message_uuid`. A message
  sent while the CLI runs its own turn is `queued` and only `started`
  after that turn's `result`. Turns the CLI starts itself have no
  lifecycle frames.
- **Subagent approvals.** `canUseTool` for a subagent's tool has `agentID`
  set, and its `tool_use` frame never reaches the runner (subagent frames
  have `parent_tool_use_id`). A background subagent can ask after the turn
  that started it has ended.
- **"Always allow" suggestions** can include `setMode: acceptEdits` and an
  `addRules` with destination `localSettings`, which writes
  `<cwd>/.claude/settings.local.json`.
- **No final newline.** `structuredPatch` hunks include `\ No newline at
  end of file` lines (not counted in the line totals).
- **Big Bash output** comes back as a `<persisted-output>` preview, with
  `tool_use_result.persistedOutputPath` naming the file holding all of it.
- **Re-sent command output.** After `/compact`, the CLI re-sends the
  assistant frames of earlier local commands (`/cost`) it kept, with new
  message ids and `local_command_source`; they're skipped.
