# Threadbare for Mac

The Mac app for Threadbare: a native window onto the threads the runner
(`../runner`) keeps going. It holds no agent state of its own. Quitting or
updating the app never stops a turn; the runner owns every CLI.

It talks to the runner over the WebSocket JSON-RPC protocol in
[`../docs/protocol.md`](../docs/protocol.md). The plan it's built from is
[`../docs/plan.md`](../docs/plan.md).

## Build and run

You need macOS 26, Xcode 27 (Swift 6.2 or later) and Python 3 for the
launcher. Node is only needed for the mock runner and the fixture tools.

```bash
bash install.sh        # release build into ~/Applications/Threadbare.app, links ~/.local/bin/threadbare
threadbare             # open it
threadbare restart     # debug rebuild and relaunch
threadbare stop        # quit the app (the runner and its agents keep going)
```

The scripts:

- `build-app.sh` builds and stages `~/Applications/Threadbare.app` (or
  `THREADBARE_APP_DIR`), swapping the old bundle out in two renames.
  `THREADBARE_BUILD_CONFIGURATION=debug` for a debug build.
- It signs with the first "Apple Development" identity in your keychain
  (override with `THREADBARE_SIGN_IDENTITY`), so the app keeps one identity
  across rebuilds and notification permission sticks. Without one it signs ad
  hoc and pins the designated requirement to the bundle id
  `com.mikerosoft.threadbare`, because an ad hoc requirement is the binary's
  hash and changes every build.
- `restart.sh`, `kill.sh` and `install.sh` work like Token Stats'. `kill.sh`
  only matches the staged app's own binary path.
- `icons/threadbare.png` becomes the app icon if it's there.

The app finds the runner through its data folder,
`~/Library/Application Support/Threadbare/` (`runner.json` for the port,
`secrets/runner-token` for the token). `--data-dir <path>` or
`THREADBARE_DATA_DIR` points it somewhere else, which is how the mock runner
and the perf run stay away from the real one. Install the runner itself with
`../runner/scripts/install-runner.sh` (a LaunchAgent; see the runner's README).

## Using it

- **Sidebar.** Needs you (waiting on an approval or a question, or finished
  and unread), Running, then Inbox. Each row has the title, a one-line
  preview, a relative time, a status dot, and a small account badge (the
  part of its email before the @) only if it isn't on `claude-main`.
  Snoozed and Archive are buttons at the bottom.
- **New thread** with ⌘N. It starts in `~/dev/me/misc` on the last account you
  used. The folder, account, model and "Ask before edits" are small menus on
  the composer; change them if you want, you never have to. Folder, model
  and "Ask before edits" apply to that one thread; the next starts from the
  defaults again. The account sticks.
- **Composer.** Return sends, Shift-Return adds a line. Paste or drop images;
  they go through `media.import` into the runner's `inbox/` and show as
  thumbnails you can remove before sending. Stop (⌘.) while a turn runs. If
  the runner is down, or it doesn't take the message (busy, say), the text
  and images stay in the box (or go back into it) and a banner says why.
- **Snooze** from the toolbar, the Thread menu or a row's menu: 1 hour, this
  evening 6 pm, tomorrow 9 am, next Monday 9 am, or pick a time. The time is
  worked out when you choose, not when the menu was built. The thread comes
  back marked unread.
- **Archive** with ⌘E. The Archive view lists archived threads, newest first,
  with search and an Unarchive button on each. Archived threads open as fast
  as live ones.
- **Search** with ⌘K or ⌘F (titles and previews, archived included).
- **Approvals and questions** show as a card in the transcript with Allow,
  Always allow and Deny, or the question's options plus "Something else".
  "Something else" answers the last question: it replaces a single choice
  (typing clears the chosen option) and is added to multiple ones.
  Threads waiting on you float to Needs you and post a notification when
  you aren't looking at them.
- **Copy.** Right-click a row for Copy message. "Copy transcript as Markdown"
  (⇧⌘C, or the ... menu) copies the whole thread, fetching older pages first.
- **Images** in the transcript are thumbnails; click one for Quick Look.
- If the runner isn't running you get "Can't reach the runner." with
  **Start runner** (`launchctl kickstart` of
  `com.mikerosoft.threadbare.runner`) and Try again; the reason is in its
  tooltip. A dropped connection says "Lost the connection to the runner.
  Reconnecting…". The app reconnects on its own with backoff (0.25 s
  doubling to 10 s), closing each failed attempt's socket, and catches each
  open thread up from the last event it had. A "not connected" banner goes
  away when the connection is back.

## How the transcript works

The transcript is a view-based `NSTableView` inside the SwiftUI window, one
row per item: your message, assistant text, thinking (collapsed), a tool call
with its result (one line with an icon, click to expand), a diff for
Edit/MultiEdit/Write, an image grid, an approval or question card, a plan, a
turn footer (duration and cost), a note or an error.

- `ThreadbareCore` turns protocol events into rows (`TranscriptModel`), keeps
  live events in seq order and spots gaps (`ThreadFeed`), splits markdown into
  blocks (`MarkdownBlocks`) and builds diffs (`DiffBuilder`). It has no AppKit
  or SwiftUI, so it's all unit tested.
- Assistant text is rendered with swift-markdown into an `NSAttributedString`
  and shown in a read-only, selectable TextKit 1 `NSTextView`. Code blocks are
  monospaced on a rounded background; inline code gets a small pill.
- Every row's render and height is cached by (row id, content version,
  expanded, reading column width). Opening a thread renders its newest 200
  rows across all cores before the table sees them, so the main thread only
  reads the cache. The column is at most 780 pt, so on most window sizes a
  resize, a sidebar drag or a scroll bar appearing changes no render at all.
  Rows are laid out at the scroll view's width less a legacy scroller's
  whether or not one is showing, so threads aren't laid out twice as the
  scroller comes and goes. A streaming row keeps only its newest render in
  the cache.
- A thread opens at the bottom with the newest 500 events (about 200 rows
  shown). Scrolling up pages older rows in, keeping the row at the top of
  the screen exactly where it was (the anchor is read before the rows
  change). When paging changes the order of rows already shown (a tool
  result on the newer page whose call is on the older one), the table is
  reloaded around that anchor instead. A long thread left at the bottom
  drops back to its newest page when you switch away.
- Streaming is coalesced to at most 30 updates a second. Finished markdown
  blocks are cached, so only the open block is re-rendered and re-measured
  (the finished blocks keep their TextKit layout in a measuring stack of
  their own, as they do in the cell); the row is updated in place with
  `noteHeightOfRows` and no animation. The view follows the bottom only if
  you're already there. Off-screen streaming rows are re-measured a few
  times a second, not on every delta.
- Text taller than about a screen and a half (a long reply, an expanded
  tool output or diff) is drawn through a slice: the text view's frame
  covers what's on screen plus half a screen either side, with its bounds
  origin moved to match, and the slice follows as you scroll. A layer-backed
  view otherwise keeps a backing store its full height (36 MB for a
  2,900 pt reply at 2x). Rows parked off screen drop their drawing.
- Changing the width of a long thread (a live resize or a sidebar drag)
  re-measures the rows on screen and 60 either side straight away and the
  rest off the main thread once the resizing stops.
- Events are read leniently: a known event in a shape the app doesn't
  expect keeps its seq and shows what it can (or nothing), so it never
  leaves a hole in the seq order. If the runner really is missing a seq,
  the thread skips it after three catch-up fetches that don't fill it,
  waiting a little longer before each.
- Image thumbnails take their size from the file header for layout and are
  decoded off the main thread at the size they're drawn, into a 24 MB cache.
  Rows the table parks off screen let go of their images.

## The mock runner

`Tools/mock-runner` is a small Node WebSocket server that speaks the protocol,
for working on the app without the real runner. It serves the synthetic demo
threads in `Tools/mock-runner/fixtures` (made up, safe to commit; regenerate
with `node Tools/mock-runner/make-synthetic.mjs`) plus any private fixtures in
`.fixtures/`, fakes a turn when you send a message (say "approval" or
"question" in it to get a card), and has a `mock.stream` method that replays
a 30 Hz stream for perf runs.

```bash
(cd Tools/mock-runner && npm install)
threadbare mock              # the app against the mock, in a temp data folder
threadbare mock --filler 16  # plus 16 synthetic filler threads
```

It never touches the real runner's data folder (it refuses to).

## Fixtures from real transcripts

`Tools/fixture-export/export.mjs` turns Claude Code JSONL transcripts (from
`~/.claude/projects` and each Token Stats account's `projects` folder) into
protocol event fixtures in `.fixtures/`, which is gitignored: they're Mike's
private conversations.

```bash
node Tools/fixture-export/export.mjs --pick 87,451,2114,4100   # sessions nearest these row counts
node Tools/fixture-export/export.mjs --session <file.jsonl> --name my-thread
node Tools/fixture-export/export.mjs --count <file.jsonl>
```

Row counts use the same rules as the app's reducer, images included. On
2026-10-26 the closest real sessions were 86, 449, 2,063 and 4,295 rows.

## Perf runs

```bash
bash Tools/perf-run.sh                       # or: threadbare perf
bash Tools/perf-run.sh --stream-seconds 10   # shorter streaming step
```

This builds a release app into a temp folder and starts the mock runner with
the fixtures, 16 real-size copies of the three biggest fixtures (symlinked
events and media under their own thread ids, in the temp folder only) and 16
filler threads, then runs the app with `--perf-run`:

1. Opens the biggest fixture as the very first thing after launch (the 100 ms
   bar), then each other fixture for the first time.
2. Switches between the fixtures 24 times.
3. Flings the biggest one to the top and back with a display link at
   9,000 pt/s. Every frame it checks that the row at the top of the screen
   hasn't moved since the last frame (a jump), and it compares how far it
   scrolled up with how far down: paging all of the thread in should make
   them match.
4. Live-resizes the window with every row of that thread shown, timing each
   4 pt step.
5. Streams into it for 60 s at 30 Hz with a tool call and result persisted
   every 1.5 s (each with a `thread.updated`), scrolled up, checking the row
   being read stays put; then the same pinned to the bottom, with CPU per
   10 s.
6. Opens 20 threads (the 4 fixtures and the 16 copies), switches to the
   biggest, and reads phys_footprint after 1 s and 6 s, plus the peak over
   the whole run.

It ends with each bar from the plan marked met or NOT MET. Intervals are
also marked with `os_signpost` (subsystem `com.mikerosoft.threadbare`,
category `perf`) for Instruments. The report prints and is saved to
`.fixtures/perf/`. `--perf-debug` adds the transcript's cells, layer tree and
memory regions after each open; `--perf-hold <seconds>` keeps the app open at
the end; `--perf-window 1280x860` sets the window's content size (the
default). The fling scrolls the clip view directly, not with real trackpad
momentum events.

Latest run, `.fixtures/perf/perf-20261026-170313` (M5 Pro, 64 GB, macOS
26.6.2; window inactive behind other apps). Ranges are over the three full
60 s runs on 2026-10-26 (`perf-20261026-164310`, `-165818`, `-170313`):

| Bar from the plan | Result |
|---|---|
| Open a 4,100-row thread to first paint, 100 ms or less | 75 ms for the 4,295-row fixture as the very first thing opened after launch (61 to 99 ms over three runs; the slow runs are the ones where the window's first GPU allocation, below, lands inside the open). The other fixtures, each opened for the first time: 46 to 49 ms |
| Switch threads, 50 ms or less | median 20 ms, p95 29 ms, max 33 ms (24 switches) |
| Fling top to bottom, no hang over 100 ms, no jumps | up through 26 older pages and back, 306,369 pt each way in 34 s each, all 4,295 rows reached: 0 jumps, max frame gap 37 ms, 0 frames over 100 ms |
| Live resize (not a plan bar; the 100 ms hang rule) | 28 ms median, 34 ms max per 4 pt step with all 4,295 rows shown; the rest re-measured off the main thread 366 ms after the last step |
| 60 s of 30 Hz streaming while scrolled up, 30% of a core or less | 8.3% with a tool call and result persisted every 1.5 s; the row being read stayed put. Pinned to the bottom for 60 s: 16.9%, flat (13 to 18% in each 10 s) |
| 200 MB or less with 20 threads loaded and the biggest open | Not met 1 s after the last switch: 253 MB, of which 105 MB is GPU memory (see below). 152 MB 6 s later, with 7 MB of graphics. The other 16 threads are real-size copies of the fixtures |

The memory number 1 s after a burst of opens includes about 87 to 105 MB of
"owned unmapped (graphics)" memory. It's allocated, all at once, the first
time the transcript draws in a 1,280 by 860 window (it doesn't appear at all
at 800 by 500), and the system takes it back after about 5 s with nothing
drawing. The app's own memory (heap, renders, events for 20 real-size
threads) is about 150 MB. Peak over a whole run is about 350 MB, during the
fling, with every row of the biggest thread loaded and rendered.

Other numbers from the same run: launch to window 589 ms (the first launch
of a freshly signed build), older page fetch 13 ms and merge 9 ms (median).

## Screenshots

`Threadbare --data-dir <mock data dir> --screenshots <folder>` opens the demo
threads and saves window-only captures (`screencapture -l` with the window's
id, never the full screen). `--only 2` takes just one. Run the mock with
`--fixtures Tools/mock-runner/fixtures` so only the synthetic threads are
there. Steps 6 and 7 stream a long synthetic reply (captured while it
streams, at its end and in its middle) and type into the composer.

## Driving it from a script

Debug builds launched with `--automation <log file>` take commands from
`Tools/drive.sh` (distributed notifications), so a script or an agent can use
the app's own UI paths without bringing the window to the front or needing
accessibility access: select a thread, set the new-thread folder, account,
model and "Ask before edits", type into the composer and press Return, paste
an image (through a private pasteboard, never the clipboard), click a button
in the transcript (Allow, Always allow, Deny, a question's option, Send
answer), archive, unarchive, snooze, switch the sidebar view, scroll, and
read the app's state back. It posts no notifications while scripted. Release
builds don't include it.

```bash
bash restart.sh && bash kill.sh     # a debug build in ~/Applications
open -g ~/Applications/Threadbare.app --args --automation /tmp/tb-drive.log
Tools/drive.sh '{"cmd":"select","id":"<thread id prefix>"}' '{"cmd":"click","title":"Allow"}'
Tools/drive.sh '{"cmd":"status"}'; tail -1 /tmp/tb-drive.log
```

`account-ids` shows accounts by id instead of email address, for
screenshots. The integration run on 2026-10-26 used this against the real
runner; its window-only captures are in `../docs/screenshots/`.

## Tests

```bash
swift test
```

`ThreadbareCoreTests` covers the protocol models (including events in
shapes the strict decoders used to reject), the JSON-RPC client over a fake
transport (request order, timeouts), the reducer and feed (streaming across
earlier finished turns, gaps and unfillable holes, paging and moved rows,
trimming), markdown blocks, diffs, snooze presets, sidebar sections, image
headers and the Markdown export. `MockRunnerTests` runs the real WebSocket
client against the mock runner (skipped if node or the mock's `npm install`
is missing). `ThreadbareAppTests` tests the app target itself: typing into
the composer, question answers, incremental streaming heights against a
full measure, the render cache, sliced tall text, and drafts kept when a
send fails.

`--screenshots` also checks two things as it goes: a long streamed reply
(drawn through a slice, captured at the end, in the middle and while it
streams) and text typed into the composer reaching the draft.

## Known gaps

- Perf has only been run on the M5 Pro, not on Tinker Desk (M2, 16 GB).
- Thumbnails aren't prefetched ahead of a fast scroll, so tiles can show
  blank for a moment, and they're decoded again on each pass.
- The app target is still in Swift 5 language mode (its TextKit measuring
  runs off the main thread with non-Sendable objects kept to one thread
  each); `ThreadbareCore` is Swift 6.
- No syntax colouring in code blocks yet.
- The model menu offers opus, sonnet and haiku by name; the runner passes the
  name through to the CLI.
