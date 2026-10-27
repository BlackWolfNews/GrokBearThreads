# Threadbare: Mike's own agent app

Working name. It's a thread app with only the things Mike uses and nothing
more, hence threadbare. Easy to rename while it's young.

## Why

Mike runs most of his work through T3 Code, a desktop app that drives Claude
Code and Codex as threads. He likes snoozing threads, settling them and getting
archived ones back quickly, provider updates and usage stats. He doesn't like
being made to pick a project every time (it's nearly always misc), Codex image
generation not showing up, images being half broken in general, the Electron
app weight, and agents dying when the app quits or updates. He wants an app
that opens fast, stays light with lots of threads, does exactly what he uses,
and later shows his threads on his phone and runs work on other machines.

## Shape

Two pieces, both on Mike's MacBook to start:

1. **Runner** (`runner/`, TypeScript on Node 24): a launchd daemon that owns
   every agent process. It drives the official CLIs only: Claude Code through
   the Claude Agent SDK (the same way T3 does), Codex through `codex
   app-server` later. It persists threads, normalises events, stops idle CLIs
   and resumes them by session id, and serves a local WebSocket JSON-RPC API
   (see `docs/protocol.md`). Quitting or updating the app never kills a turn.
2. **App** (`app/`, Swift, SwiftPM, macOS 26): a native SwiftUI shell with an
   AppKit `NSTableView` transcript. It's a client of the runner and holds no
   agent state of its own.

Later steps (not in this build): Codex adapter, Token Stats usage in the app,
CLI auto-updates, thread summaries to Convex plus a Threads tab and push in
Quick Ask, Tinker Desk as a second runner, cloud sandboxes.

## Behaviour Mike asked for

- **No project picker.** New threads start in `~/dev/me/misc` on the last-used
  account. The folder, account and model are small controls on the composer
  you can change if you want, never a required step.
- **Snooze** a thread until a time (presets: 1 hour, this evening 6 pm,
  tomorrow 9 am, next Monday 9 am, pick a time). It disappears from the list
  and comes back marked unread when the time passes. Snoozing stops its CLI.
- **Archive** (Mike calls this settling) with ⌘E: the thread leaves the inbox
  and its CLI stops. The Archive view lists archived threads newest first with
  search, and "Unarchive" puts one straight back. Archived threads are as
  quick to open as live ones.
- **Images work.** Pasted or dropped images are saved as files and sent to the
  agent; images agents read or generate are saved into the thread's media
  folder and shown inline as thumbnails; click opens Quick Look.
- **Speed.** Cold start to a usable window well under a second. Switching
  threads feels instant. Hundreds of threads and transcripts of 4,000+ rows
  stay smooth. Idle threads cost nothing (no CLI running).
- **Light.** Only threads that are running or were used in the last 30
  minutes keep a CLI process.

## Runner details

- Data dir `~/Library/Application Support/Threadbare/`:
  `runner.json` (port, defaults), `secrets/runner-token` (0600, random),
  `threads/<threadId>/thread.json` (summary, atomic writes),
  `threads/<threadId>/events.ndjson` (append-only persisted events),
  `threads/<threadId>/media/` (images), `threads/<threadId>/blobs/` (tool
  output over 64 KB), `inbox/` (images the app drops before sending),
  logs in `~/Library/Logs/threadbare-runner.log`.
- Listens on `127.0.0.1:8797`, WebSocket path `/rpc`, bearer token from the
  secrets file (header on upgrade, or first-message `auth`).
- launchd LaunchAgent `com.mikerosoft.threadbare.runner`, KeepAlive, with the
  Node path pinned in the plist (`~/.nvm/versions/node/v24.22.1/bin/node`
  today; make it configurable). Don't use `node:sqlite` (it truncates text
  at NUL on Node 24); plain files are enough.
- **Accounts.** Discover Claude logins: `~/.claude` (id `claude-main`) and each
  `~/Library/Application Support/Token Stats/Accounts/claude-N` (id
  `claude-N`). Title from the login's email in its `.claude.json`
  (`oauthAccount.emailAddress`; read only that field, never tokens).
- **Claude adapter** (`@anthropic-ai/claude-agent-sdk`, pin the current
  version, 0.3.310 on 2026-10-26):
  - One `query()` per live thread in streaming-input mode (an async queue).
  - `pathToClaudeCodeExecutable` = `~/.local/bin/claude`, the shared native
    install (SDK sessions never update it: only the terminal UI,
    `claude update` and `claude install` do, so step 4 adds Threadbare's own
    update checks); `env` = `{...process.env, CLAUDE_CONFIG_DIR}` for
    non-main accounts (and with `CLAUDE_CONFIG_DIR` removed for `claude-main`).
  - `cwd` per thread; `settingSources: ['user','project','local']`;
    `systemPrompt: {type:'preset', preset:'claude_code'}`;
    `includePartialMessages: true`; thinking summaries on.
  - New thread: pre-assign `sessionId` (uuid). Resume: `resume: sessionId`.
  - Permission mode per thread: `full` (default, `bypassPermissions` with
    `allowDangerouslySkipPermissions`, which is how Mike runs T3) or `ask`
    (`default` mode with `canUseTool` turned into approval events).
    `AskUserQuestion` always surfaces as a question event the app answers.
  - Model: omit to use the account's settings default; optional per-thread
    override.
  - Interrupt with `query.interrupt()`.
  - Idle release: 30 minutes after a turn ends with nothing pending, or
    immediately on snooze/archive, end the input so the CLI exits. The next
    send starts a new `query()` with `resume`. Never run two live queries on
    one session. Kill the CLI's process group if the runner exits.
  - Title: first line of the first message, trimmed to 60 characters,
    then a small model's title once there's an OpenRouter key (src/models/).
- **Adapter interface** so Codex can be added without touching the rest.
- **Startup:** threads that were live when the runner stopped become
  `stopped`; any approval that was pending is marked expired.
- Write a small CLI, `runner/bin/tb`, for testing and scripting: `tb new
  "text" [--cwd] [--account]`, `tb send <id> "text"`, `tb list`, `tb tail
  <id>`, `tb archive <id>`.

## App details

- SwiftPM package in `app/`: `ThreadbareCore` (no AppKit/SwiftUI: protocol
  models, WebSocket JSON-RPC client, event reducer that turns events into
  transcript rows, markdown block splitter, diff builder), `Threadbare`
  (executable: SwiftUI + AppKit), `ThreadbareCoreTests` (XCTest). swift-tools
  6.2, macOS 26. Copy Token Stats' `build-app.sh`, `restart.sh`, `kill.sh`,
  `install.sh` and launcher pattern
  (`~/dev/me/mikerosoft-tools/token-stats`); bundle id
  `com.mikerosoft.threadbare`; sign with the first "Apple Development"
  identity, falling back to ad hoc, with a stable designated requirement.
- **Window:** `NavigationSplitView`. Sidebar sections: Inbox (everything not
  running, what needs Mike first: questions and approvals, then unread
  replies, then the rest; Needs you merged into it 27 Oct), Running at the
  bottom, then a footer button for Snoozed and Archive views. Each row: title,
  one-line preview, relative time, small status dot, account badge only if
  it isn't the default. ⌘N new thread, ⌘E archive. (No inbox search since
  design pass 1; the Archive view keeps its own.)
- **Transcript:** view-based `NSTableView` in an `NSViewRepresentable`, one
  row per item: user message, assistant text, reasoning (collapsed), tool
  call with result (one collapsed line with an icon and a short title,
  expandable), diff (for Edit/MultiEdit/Write), image grid, approval or
  question card, turn footer (duration, cost), error. Rules from the research:
  - Assistant text rendered with swift-markdown into an `NSAttributedString`
    in a non-editable, selectable TextKit 1 `NSTextView`
    (`usingTextLayoutManager: false`). Code blocks monospaced with a subtle
    background; syntax colouring can come later.
  - Row heights cached by (row id, content version, width); measured off the
    main thread where possible.
  - Open at the bottom with the last ~200 rows and page older ones in when
    scrolling up, keeping the visible row anchored.
  - Streaming: coalesce to at most 30 updates a second; finished markdown
    blocks are frozen; only the last open block is re-rendered; update one
    row with `noteHeightOfRows` and no animation; follow the bottom only if
    the user is already at the bottom.
  - Drive the table with row inserts and reloads, not full reloads.
  - Images: read pixel size from the file header for layout, decode
    thumbnails off the main thread at drawn size into an `NSCache`.
  - Copy message and "Copy transcript as Markdown" since selection can't span
    rows.
- **Composer:** multi-line text view at the bottom, Return sends,
  Shift-Return newline, paste or drop images (saved into the runner's
  `inbox/`), Stop while running, and small menus for folder, account, model
  and "Ask before edits".
- **Approvals and questions:** a card in the transcript with Allow, Always
  allow and Deny (or the question's options). Threads that need Mike float to
  Needs you and post a local notification when the app isn't showing them.
- **Runner connection:** reconnect with backoff; if the runner isn't running,
  show a plain message with a Start button (`launchctl kickstart`).
- Copy: plain words, no eyebrow or kicker labels, no em dashes.

## Performance bar

On the M5 and Tinker Desk (M2, 16 GB):
- open a 4,100-row thread to first paint in 100 ms or less,
- switch threads in 50 ms or less,
- fling top to bottom with no hang over 100 ms and no jumps when not pinned,
- 60 s of 30 Hz streaming while scrolled up uses 30% of one core or less,
- 200 MB or less with 20 threads loaded and the biggest one open.

`app/Tools/fixture-export` turns real Claude JSONL into event fixtures
(gitignored, they contain private text) for these tests.

## Trial

Use it next to T3 for a week. If the transcript isn't nicer than T3's, stop:
the shared memory and the Connectors gateway are worth having anyway.
