# Threadbear for Mac

The Mac app for Threadbear: a native window onto the threads the runner
(`../runner`) keeps going. It holds no agent state of its own. Quitting or
updating the app never stops a turn; the runner owns every CLI.

It talks to the runner over the WebSocket JSON-RPC protocol in
[`../docs/protocol.md`](../docs/protocol.md). The plan it's built from is
[`../docs/plan.md`](../docs/plan.md).

## Build and run

You need macOS 26, Xcode 27 (Swift 6.2 or later) and Python 3 for the
launcher. Node is only needed for the mock runner and the fixture tools.

```bash
bash install.sh        # release build into ~/Applications/Threadbear.app, links ~/.local/bin/threadbear
threadbear             # open it
threadbear restart     # debug rebuild and relaunch
threadbear stop        # quit the app (the runner and its agents keep going)
```

The scripts:

- `build-app.sh` builds and stages `~/Applications/Threadbear.app` (or
  `THREADBEAR_APP_DIR`), swapping the old bundle out in two renames.
  `THREADBEAR_BUILD_CONFIGURATION=debug` for a debug build.
- It signs with the first "Apple Development" identity in your keychain
  (override with `THREADBEAR_SIGN_IDENTITY`), so the app keeps one identity
  across rebuilds and notification permission sticks. Without one it signs ad
  hoc and pins the designated requirement to the bundle id
  `com.mikerosoft.threadbear`, because an ad hoc requirement is the binary's
  hash and changes every build.
- `restart.sh`, `kill.sh` and `install.sh` work like Token Stats'. `kill.sh`
  only matches the staged app's own binary path.
- `icons/threadbear.png` becomes the app icon if it's there.
- The bundle records what it was built from in `Contents/Resources/build.json`
  (commit, the tree hash of `app/`, the checkout), and carries
  `stage-update.sh`.

The installed app then keeps itself current (`AppUpdate.swift`). Every five
minutes it reads main's tree hash for `app/` in the checkout it was built
from; when that differs from what's running it builds the commit in the
background with `stage-update.sh` (release, `nice`d, from a clone of main
under `~/Library/Caches/Threadbear/update`, so an agent's half-done edits
in the working tree are never built) into `~/Applications/.Threadbear.app.next`.
Quitting swaps the staged bundle into place, so the next launch is the new
app; a launch that finds one staged (the app was killed rather than quit)
swaps it in and relaunches; "Restart to Update to <commit>" in the app
menu does it right away. It also restarts by itself, checked every 30 s,
once no thread is running or starting, no composer has unsent text or
images, and either another app is in front (it relaunches behind, with
`open -g`) or Threadbear is in front but hasn't had a key or a click for
five minutes; the thread and list that were open come back after. The
build's output goes to
`~/Library/Logs/threadbear-update.log`; the app's own log says what it
decided. Only the installed bundle path does this, not a dev app, perf or
screenshot run, and `--no-update` turns it off for a launch. An app built
before `build.json` existed stays as it is until `install.sh` or
`restart.sh` is run once.

The app finds the runner through its data folder,
`~/Library/Application Support/Threadbear/` (`runner.json` for the port,
`secrets/runner-token` for the token). `--data-dir <path>` or
`THREADBEAR_DATA_DIR` points it somewhere else, which is how the mock runner
and the perf run stay away from the real one. Install the runner itself with
`../runner/scripts/install-runner.sh` (a LaunchAgent; see the runner's README).

## Using it

- **Sidebar.** New thread at the top, then Needs you (waiting on an
  approval or a question, or finished and unread), Running, then Inbox.
  Each row has the title, a one-line preview, and at the right the time or
  the status in words: "Working" with a spinner, "Needs you" in orange,
  "Failed" or "Stopped". A finished thread you haven't read has a blue dot
  before its title. The account (the part of its email before the @) shows
  at the end of the preview only if it isn't on `claude-main`. Hover a row
  for Snooze and Archive buttons. A click selects a row straight away, and
  the up and down arrows move through threads from there. Snoozed and
  Archive, with their counts, are at the bottom. There's no search in the
  inbox; the archive has its own.
- **Header.** One line: the folder's name, then the title. The full path is
  in its tooltip. The ... menu has Snooze, Archive, "Copy transcript as
  Markdown" and "Copy thread id" (for pointing an agent at the thread).
- **New thread** with ⌘N or the New thread row. The composer sits in the
  middle of the pane under "What should we work on?", with where the thread
  will start ("Starts in misc on mike") under it, and drops to the bottom
  once you send. It starts in `~/dev/me/misc` on the last account you used.
  The account and "Ask before edits" are small menus on the composer,
  and "+" > Folder changes the folder; the folder only gets a chip of its
  own when it isn't the runner's default. The model chip names the model a
  thread really runs on ("Fable 5.1", not "Default") and the effort level
  once one is chosen or the CLI has reported it ("Fable 5.1 · High"). It
  opens a picker laid out like T3 Code's: providers down the left (Claude
  for now; Codex and others are columns of their own when they come), a
  search box, what the account's CLI offers by the CLI's own names with a
  star on the default and older models under the rest, and the effort
  level (Low to Max) along the bottom. Change them if you want, you never
  have to. The folder and "Ask before edits" apply to that one thread; the
  next starts from the defaults again. The account, model and effort stick:
  whatever you picked last, on any thread, is what the next one starts on.
- **Composer.** Return sends, Shift-Return adds a line. Paste or drop images,
  or "+" > "Attach images…";
  they go through `media.import` into the runner's `inbox/` and show as
  thumbnails you can remove before sending. Stop (⌘.) while a turn runs. If
  the runner is down, or it doesn't take the message (busy, say), the text
  and images stay in the box (or go back into it) and a banner says why.
- **The tour.** The first time the app connects to a runner it dims the
  window and lights up its parts one at a time (the views down the left,
  the threads, the composer, Highlights, Usage) with a card beside each.
  Return goes on, Esc skips it, and Help > Take the Tour runs it again.
  It only points at things; it never starts a thread.
- **Snooze** from a row's hover button, the Thread menu, the ... menu or a
  row's right-click menu: 1 hour, this evening 6 pm, tomorrow 9 am, next
  Monday 9 am, or pick a time. The time is worked out when you choose, not
  when the menu was built. The thread comes back marked unread.
- **Archive** with ⌘E (⌘E on an archived thread brings it back), a row's
  hover button or its menus. The Archive view lists archived threads, newest
  first, with search; hover a row for Unarchive. Esc goes back to the inbox.
  Archived threads load with the rest, so they open as fast as live ones.
- **Approvals and questions** show as a card in the transcript with Allow,
  Always allow and Deny, or the question's options plus "Something else".
  "Something else" answers the last question: it replaces a single choice
  (typing clears the chosen option) and is added to multiple ones.
  Threads waiting on you float to Needs you and post a notification when
  you aren't looking at them.
- **Copy.** Right-click a row for Copy message. "Copy transcript as Markdown"
  (⇧⌘C, or the ... menu) copies the whole thread, fetching older pages first.
  "Copy debug info" (on every row's menu) copies the thread id, the row's id
  and kind, its turn, the seqs of the events it was built from and the
  runner's version, one `key: value` a line, and the `tb events <thread>
  --from N --to M` command that prints those events. Against a dev runner
  it names that runner's own `<home>/tb` (a bare `tb` in a thread reaches
  the live one); against the mock, the lines of the fixture's events.ndjson
  (line N is seq N).
- **Images** in the transcript are thumbnails; click one for Quick Look.
- **Runner restarts** (`runner.restart`, the deploy script) show as a
  quiet grey line under the toolbar, not the yellow banner: "The runner
  will restart when 2 threads finish." (the threads' titles are in its
  tooltip; the count follows `runner.status` as threads finish). Threads
  waiting on your answer are counted apart, since they won't finish until
  you answer: "The runner will restart when 1 thread finishes and you
  answer 2." Then "The
  runner is restarting. Reconnecting…" with a spinner while it's down. The
  app retries every half second then, and the line goes once it's back. A
  runner that isn't back within 90 seconds gets the usual banner. The
  message the runner sends to carry a thread on (`origin: "runner"`) is a
  small centred note under the "Runner restarted" one, "Sent by the runner
  after it restarted" over its text, not a bubble of yours.
- If the runner isn't running you get "Can't reach the runner." with
  **Start runner** (`launchctl kickstart` of
  `com.mikerosoft.threadbear.runner`; only shown when the app uses the
  installed runner's data folder, never against the mock or a dev runner)
  and Try again; the reason is in its tooltip. A dropped connection says "Lost the connection to the runner.
  Reconnecting…". The app reconnects on its own with backoff (0.25 s
  doubling to 10 s), closing each failed attempt's socket, and catches each
  open thread up from the last event it had. A "not connected" banner goes
  away when the connection is back.

## How the transcript works

The transcript is a view-based `NSTableView` inside the SwiftUI window, one
row per item: your message, assistant text, thinking, a tool call with its
result (one line with an icon, click to expand), a diff for
Edit/MultiEdit/Write, an image grid, an approval or question card, a plan, a
turn footer (duration and cost), a note or an error.

- A run of work inside one turn (thinking, tool calls with their results
  and diffs, notes) folds into one group row: "Read 2 files, searched
  twice, ran a command". Click it to open it. A run of one item shows as
  that item. Messages, cards, plans, images, errors and footers are never
  folded. The model keeps both lists: `items` (one per item, for copy and
  export) and `rows` (what the table shows).
- While a turn runs, the last row is "Working for 12s" with a spinner, and
  the turn's live group adds the current action after a dot.
- A turn that edited files ends with an "Edited 3 files" card (name, folder,
  +N −M); click a file for its diff.

- `ThreadbearCore` turns protocol events into rows (`TranscriptModel`), keeps
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
a 30 Hz stream for perf runs. `--fixtures DIR` (repeatable) serves only
those: a folder of fixtures, or one `tb export` folder. The demo threads'
times are moved at load so the newest is a minute old, as when they were
made, so design shots don't age by the hour; exports keep their own.

`mock.updates` plays the runner's own update for the rail's updates icon
(`state`, `commit`, `subject`, `reason`, `oldRunners: [{ version, threads }]`,
`launcherChanged`); threads named in `oldRunners` get `onOldRunner`.

It also answers `runner.status`, and fakes a runner restart for the app's
restart states: `mock.restartPending` (`waitingFor`, default the busy
threads; `resume: {threadId}`; `cancel: true`) saves one and sends the
notice, and `mock.restart` (`downMs`, default 3000; `resume: {threadId,
text}`) sends "The runner is restarting now.", drops every connection,
closes the port for `downMs`, comes back on the same port as
`0.0.0-mock+r1`, and carries the resumed thread on with the "Runner
restarted" note and a turn whose message has `origin: "runner"`. As with
the real runner, nothing is mid-turn across it: the threads a pending idle
restart waited for finish just before it (those waiting on Mike stay
waiting), and any other running turn ends interrupted with the thread
stopped.

`mock.background` (`threadId`, `tasks: [{ kind, description, finished? }]`;
empty clears it) sets what a thread's CLI is still running in the
background between turns, as the real runner's `background` summary field
does, so the sidebar's "3 sub-agents" row and the transcript's background
line can be seen without waiting on a real sub-agent. The demo thread
"Rebuild the three landing pages" starts that way.

`mock.showPanel` (`threadId`, `panel`, `where?`) puts a panel request on a
thread as the agent's `show_panel` does (docs/protocol.md, "Showing
panels"), with the panel's id as the real runner sends it
(`convex.dashboard`, not "Convex"): the app shows it once it's on that
thread and in front (`{"cmd":"focus"}` for a scripted one). `mock.panelState`
(`threadId`) says what's still waiting there and which requests the app has
said it showed.

```bash
(cd Tools/mock-runner && npm install)
threadbear mock              # the app against the mock, in a temp data folder
threadbear mock --filler 16  # plus 16 synthetic filler threads
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
bash Tools/perf-run.sh                       # or: threadbear perf
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
also marked with `os_signpost` (subsystem `com.mikerosoft.threadbear`,
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

`Threadbear --data-dir <mock data dir> --screenshots <folder>` opens the demo
threads and saves window-only captures (`screencapture -l` with the window's
id, never the full screen). `--only 2` takes just one. Run the mock with
`--fixtures Tools/mock-runner/fixtures` so only the synthetic threads are
there. Shots 1 to 4 are demo threads (approval card, plan and diffs, an open
work group, a question), 5 the archive with a row's Unarchive button, 6 a
long reply streaming (while it streams, at its end and in its middle), 8 a
running turn and the demo's edits (a group with its diffs open, the changes
card with a file open), 7 the new-thread composer (typed, with an image,
with a long draft), 9 an inbox row's hover buttons, 10 a failed tool and
answered cards, and 11 a runner restart (the quiet banner while it waits,
reconnecting while it's down, and the thread it carried on, with the
runner's message as a note; last, since it restarts the mock).
`Tools/screenshots.sh <dir> [--only <prefix>] [--appearance light|dark]`
(options in any order, `--help` for the usage) does all of this in a temp folder with the window kept behind yours, under
a bundle id of its own (so it never reads or writes the installed app's
settings; it used to leave its window size in them). It runs the binary
from your shell, so screencapture has the shell's Screen Recording
permission. Without it, or with the screen locked, each shot is AppKit's own
drawing of the window ("drawn in-process"): the sidebar's glass is a flat
fill and the traffic lights are approximate, and the rest matches.

## Seeing and driving it from a script

Debug builds launched with `--automation <log file>` take commands as
distributed notifications, so a script or an agent can use the app's own UI
paths without bringing the window to the front or needing accessibility
access. Each result is a line in that log; the app's own log (connection,
RPC errors, runner notices, the commands) goes beside it (`--app-log`, else
`<log>.app.log`). It posts no notifications while scripted, anything it
copies goes to its own pasteboard, never the clipboard, and window sizes it
sets are never saved. It refuses to start against the installed runner's
data folder (no `--data-dir`), since commands would then act on Mike's real
threads, unless `--automation-allow-live` is given; that's for Mike to
decide. `--automation-idle-quit <seconds>` quits it after that long with no
command. Release builds don't include it.

`Tools/dev-app.sh` is the way to use it. Each instance is a debug build in
its own temp bundle with its own bundle id (so its own settings), data
folder, notification name and pasteboard (`--automation-id`), so several
run at once; its window opens with `open -g` and goes behind everything as
soon as it's there. It's never in the Dock or the app switcher (the bundle
is `LSUIElement`), so Mike can't Cmd-Tab into one and type into it by
mistake. Its mock runner runs in a session of its own: started from an
agent's command it used to share that command's process group, which the
live runner stops when it restarts, leaving the app with no runner.

Instances belong to whoever started them: the Threadbear thread
(`THREADBEAR_THREAD_ID`) and the checkout the script is in. Several threads
can be using dev apps at once, so without `--id` a command means the
caller's newest running instance, never another thread's or another
checkout's (it says whose they are if you have none); `stop --all` stops
only yours (`--everyone`: every instance on the Mac); `status` lists them
all with whose they are; and an id another thread has is refused at
`start`. An app quits after 60 minutes with no command, and its mock runner
exits once its app has gone, so an instance nobody stopped doesn't stay
behind Mike's windows; `start` and `status` clean up after instances whose
app has quit (another thread's once it has been quiet for 30 minutes).

```bash
Tools/dev-app.sh start --mock                    # the demo threads; prints the instance id
Tools/dev-app.sh start --mock --fixtures .fixtures/threads/<id>   # a tb export
Tools/dev-app.sh start --home <dev runner home>  # runner/scripts/dev-runner.sh
Tools/dev-app.sh do '{"cmd":"open","id":"demo_upload"}' '{"cmd":"expand","row":"g:"}'
Tools/dev-app.sh dump            # sidebar, rows (id, kind, height, open, text), panels, actions, composer, banner
Tools/dev-app.sh shot /tmp/a.png # the window alone
Tools/dev-app.sh rebuild         # a new build, same options and runner, same thread open
Tools/dev-app.sh log             # the app's own log
Tools/dev-app.sh stop            # quits it, stops its mock, deletes its files and settings
```

For the Convex deployment picker, open `demo_dark_mode`, then send
`{"cmd":"mock","method":"convexPanel","params":{"threadId":"demo_dark_mode"}}`
and `{"cmd":"panel","id":"convex.dashboard"}`. The mock lists Development
and Production but has no deploy keys. `{"cmd":"convex","deployment":"busy-bear-456"}`
uses the picker's selection model; `{"cmd":"convex"}` reports the selection
and browser URL. Calling `mock.convexPanel` again reports key requests so
switching can be checked without a real Convex account.

`start` also takes `--appearance light|dark`, `--size WxH` and `--id NAME`;
every other command takes `--id` (default: your newest), and `status` lists
them, saying when an app's runner has stopped (`do`, `shot`, `dump` and
`rebuild` refuse a mock instance whose mock has). `do` waits for each
result and exits 1 on an error or a timeout.
`--home` refuses the live runner's data folder; against a dev runner whose
`runner.json` has no default model it sets the composer's to
claude-haiku-5-5 and says so, since a thread sent from it is a real turn.
`dump` shows what a send from the composer would run on (folder, account,
model and whose default it is, effort when set, access).

`shot` asks the app for its window's id and runs `screencapture -l` from
the script, in your shell: the temp bundle has no Screen Recording
permission of its own, so screencapture from inside the app always failed
(and macOS could ask Mike for it). When that gives no image (the screen is
locked, or your shell has no permission either) it falls back to the
app's own drawing, saved in the instance's folder and moved from your
shell, and says so on stderr: the sidebar's glass is a flat fill and the
traffic lights are approximate, the rest matches.

A build that fails prints just its errors (no colour codes or compiler
command lines) and keeps the whole log in
`$TMPDIR/threadbear-dev-app/build-logs/`. `rebuild` leaves the running app
alone when the build fails.

The commands (`do`), each a JSON object with `cmd`. Rows and threads can be
named by the start of their id; a start that matches more than one thread
is an error. Commands marked "the open thread" act on `id` when it's given
(an error if it names no thread) and otherwise on the thread that's open.

| cmd | fields | |
|---|---|---|
| `open` | `id`, `timeout` | selects a thread and waits until its rows are on screen |
| `select` | `id` | selects it without waiting |
| `subagent` | `thread` (default: the open one), `id`, `timeout` | shows a sub-agent's transcript, as clicking its row under the thread does, and waits until its rows are on screen |
| `mouse-button` | `button` (`back`, `forward`) | a mouse's side-button click over the window, through the same handler as a real one; says the sidebar view, the thread and whether back and forward can go further |
| `new`, `options` | `cwd`, `account`, `model` (`null` for the default), `effort` (`null` for the model's own), `ask` | the new-thread composer and its menus; `options` refuses anything else (a typo used to pass) and says what's set now |
| `composer-menu` | `menu` (`model`, `account`, `permission` or `folder`; default `model`), `click` (an item's title; an account's email or id), `show` (opens the model or account picker and says its window number) | the composer chip's menu (or the model or account picker) for the open thread or a new one, as text: `[x]` the ticked item, `*` the default, the subtitle after a dash, submenus and older models indented, `#` on a section, `---` before the account picker's line about where the numbers came from; `click` picks an item as a click would |
| `usage` | `show` (true opens the Usage panel, false closes it), `click` (`Update`, `Update anyway`, `Go back to <version>`, `Automatic`, `Ask me`, `Off` with `provider`, or `Check now`) | the Usage panel as text: each login's room by pool (`#`) and provider (`##`), then the Updates panel's CLIs with their buttons in brackets. `dump` has the same lines while it's open |
| `updates` | `show` (true opens the Updates panel, false closes it), `rightClick` (true right-clicks the icon, which opens or closes the app's update popover), `popover` (false closes that), `preview` (`staged`, `building`, `failed` or `none`: makes up the app's update, for screenshots) | whether the icon has its grey dot for the app or runner, its tooltip, whether the popover is up and its line, and the panel's app and runner lines |
| `type`, `send`, `return` | `text`, `replace`, `timeout` | types into the composer (`replace` takes the place of what's there); `send` types and presses Return, and from the new-thread composer waits for the thread it starts and prints its id |
| `rename` | `title` | without `title`, makes the open thread's title in the header a field, as a click does; with it, saves that title as Mike's |
| `paste-image` | `path` | through the instance's own pasteboard |
| `decide` | `pick` (`"ask:choice"`, both 1-based, choice 0 for "Something else"; picking the same again unpicks it), `clear`, `send` | the open thread's card of asks, picked as its buttons pick, waiting in the composer; `send` sends the composer with the picks. Says what's picked after |
| `click` | `title` | a button in the transcript: Allow, Always allow, Deny, an option, Send answer |
| `expand`, `collapse` | `row`, `file`, `all`, `section` | a group, tool, thinking block or settled approval (one folded in a closed group opens it); `file` (path or index) in a changes card; `all` for a whole diff; `section` (`inbox`, `running`) folds or opens an inbox heading, as clicking it does |
| `scroll` | `to` (`top`, `bottom`) or `row`, `offset` | |
| `hints` | `on` (default true) | shows the keys as if ⌘ were held, or hides them |
| `tour` | `do` (`start`, `next`, `back`, `end`) | the first-run tour (Help > Take the Tour): says the step, its title and the frame it lights up, or `off`. A scripted app never starts it by itself |
| `hover` | `id` (sidebar) or `row` (transcript); neither clears | draws a row as if the pointer were on it |
| `swipe` | `id`, `dx` (left negative), `steps`, `lift` (default true) | two fingers across a sidebar row, as synthetic trackpad events; `lift: false` leaves it part way for a shot. Says the offset, whether it's past the line, and whether it archived |
| `chip` | `row`, `word`, `show`, `click` | thread chips in a row's text: lists them (word=thread id); with `word`, `show` true shows its hover card and says its window number, false closes it, `click` true opens its thread |
| `select-text` | `row`, `words`, `action` | selects the first match of `words` in a message row and shows the selection bar (says its window number); `action` (`explain`, `quote` or `copy`) clicks that instead. Explain opens the pane; `dump`'s panels line shows its answers |
| `menu` | `row`, `click` | a transcript row's context menu, or chooses an item from it |
| `debug-info`, `copy-thread-id`, `clipboard` | `row`, `id` | what "Copy debug info" and "Copy thread id" (the open thread) copy, copied to the instance's pasteboard as the menu items do; `clipboard` reads it back |
| `appearance`, `resize` | `mode` (light, dark, system); `w`, `h` | |
| `zoom` | `to` (in, out, reset) or `percent` | the window's zoom, as ⌘=, ⌘- and ⌘0 set it; says the percent it's at |
| `archive`, `unarchive`, `snooze` | `id`, `seconds` (default 3600) | the open thread; says which thread it acted on |
| `mode` | `mode` (`archive`, `snoozed`, `inbox`) | which list the sidebar shows |
| `action` | `id`, `timeout` | runs that action chip of the selected thread and waits for a command to finish (default 60 s); `dump` lists the actions |
| `panel` | `id`, `show` | the selected thread's pane sections, each a panel in the window's dock: `id` opens or brings up that section (`threadbear.highlights`, a panel's id, or `threadbear.patches`; an error names the ones it has), `show` false closes every section and true opens them again (Highlights if none), neither toggles; `dump` lists the sections, the active one starred, and what Highlights has, and its `dock:` line is the whole layout |
| `preview` | `path`, `url`, `close`, `edit`, `insert` | opens a file or page in the selected thread's pane, as a click on a highlight does (a web URL goes to the browser); `close` goes back to the section. Over a text file, `edit` true or false is the bar's pencil or Done, and `insert` types text at the end of the editor (`wait` false returns before the save), `resolve` (`file` or `mine`) presses the conflict bar's button; `dump`'s preview line says `(editing)` |
| `waitFor` | `row`, `kind`, `status` (and `thread`), `text`, `banner` (`""` for none), `connection`, `loaded`, `ready`, `not`, `timeout` | until every condition given holds (default 10 s) |
| `dump` | `format` (`json`, `text`), `out` | |
| `screenshot` | `path`, `inProcess` | `screencapture -l`, or drawn in-process when that gives no image; a dev-app instance always draws in-process (`shot` runs screencapture itself). `out` and `path` are refused under ~/Desktop, ~/Documents and ~/Downloads, where macOS would ask Mike to let the temp bundle in; `shot` and `dump` write in the instance's folder and move the file |
| `window` | `panel` | the window's id (for `screencapture -l`) and size, once anything pending is drawn; with `panel`, that panel's window of its own |
| `float` | `id`, `back` | opens a dock panel (`threadbear.highlights`, say) in a window of its own, kept behind Mike's work, as its menu's Open in New Window does; `back` puts it back in the dock. Says the layout |
| `settings` | `tab` (`general`, `models`), `close` | opens the Settings window (behind Mike's windows) on that tab, or closes it; says its window number and what it shows. `shot <file> --settings`, and `window` and `screenshot` with `"settings": true`, capture it |
| `review` | `id` (optional), `mode` (`Grid`, `2-up`, `Single`), `actual` (100%), `left`, `right` (zero-based), `pick` (option ID, toggles), `notes` (object keyed by ID), `save`, `submit`, `cancel`, `close`, `popOut` | opens a review from the selected thread in the Review panel, a tab beside the main panel (`popOut`: in a window of its own, kept behind Mike's work); edits and sends through the same session as the UI. Returns the draft, status, `panel` and the window number when popped out. `window` and `screenshot` with `"review": "<review ID>"` target its window, or the main one for the panel |
| `open-panel` | `id` | opens a thread in a panel of its own beside the main panel, as the row's Open in New Panel |
| `dock-move` | `panel` (`review`, `thread:<id>` or a full id), `edge` (`left`, `right`, `top`, `bottom`) | moves a panel to a side of the window, as dragging it there does; returns the layout |
| `focus` | `on` (default true) | acts as if the app were in front, so an open thread gets marked read as it would for Mike; never activates it |
| `mock` | `method`, `params` (an object) | `mock.<method>` on the mock runner, such as `restartPending` and `restart` |
| `status`, `sidebar`, `streaming`, `account-ids`, `quit` | | |

`Tools/drive.sh` posts commands without waiting (`THREADBEAR_AUTOMATION_ID`
picks an instance). The integration run on 2026-10-26 used it against the
real runner with a debug build that replaced Mike's app in `~/Applications`;
that's his call, never an agent's, and now needs `--automation-allow-live`.
Its window-only captures are in `../docs/screenshots/`.

## Tests

```bash
swift test
```

`ThreadbearCoreTests` covers the protocol models (including events in
shapes the strict decoders used to reject), the JSON-RPC client over a fake
transport (request order, timeouts), the reducer and feed (streaming across
earlier finished turns, gaps and unfillable holes, paging and moved rows,
trimming), markdown blocks, diffs, snooze presets, sidebar sections, image
headers, the Markdown export, the runner restart's states, messages sent by
the runner, and which events each row came from ("Copy debug info").
`MockRunnerTests` runs the real WebSocket client against the mock runner,
its restart included (skipped if node or the mock's `npm install` is
missing, except under `THREADBEAR_REQUIRE_MOCK=1`, which `../check.sh` sets
after installing the mock's packages). `ThreadbearAppTests` tests the app target itself: typing into the
composer, question answers, incremental streaming heights against a full
measure, the render cache, sliced tall text, drafts kept when a send fails,
the restart banner, the runner's message as a note, and the automation
hook's channels and dump.

`--screenshots` also checks two things as it goes: a long streamed reply
(drawn through a slice, captured at the end, in the middle and while it
streams) and text typed into the composer reaching the draft.

## Known gaps

- Perf has only been run on the M5 Pro, not on Tinker Desk (M2, 16 GB).
- Thumbnails aren't prefetched ahead of a fast scroll, so tiles can show
  blank for a moment, and they're decoded again on each pass.
- The app target is still in Swift 5 language mode (its TextKit measuring
  runs off the main thread with non-Sendable objects kept to one thread
  each); `ThreadbearCore` is Swift 6.
- No syntax colouring in code blocks yet.
- The model picker lists the CLI's own rows once the runner has asked each
  account (a few seconds after it starts); until then it offers opus, sonnet
  and haiku by name. The runner passes the row's id through to the CLI.
