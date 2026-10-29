# Agent guidance for threadbear

The app was called Threadbare until 27 Oct 2026. Everything was renamed then
(repo, folders, data dir `~/Library/Application Support/Threadbear`, the
`com.mikerosoft.threadbear.*` labels and bundle id, `THREADBEAR_*`
variables). The old `THREADBARE_*` names still work as stand-ins for the
new ones, and threads still get both, for skills written before.

Threadbear is Mike's own agent app: a TypeScript runner daemon (`runner/`)
that drives the official Claude Code (and later Codex) CLIs, and a native
SwiftUI + AppKit Mac app (`app/`) that talks to it over the protocol in
`docs/protocol.md`. Read `docs/plan.md` and `docs/protocol.md` before changing
anything. The Convex mirror, the iPhone app (`ios/`) and the website (`web/`)
are in `docs/convex-backend.md` and `docs/website.md`. The public landing
page (threadbear.mikecann.app, not deployed yet) is `site/`, a separate
static site with its own `package.json`; its comments say how to build it.

## Rules

- Test first for anything non-trivial. Runner: `npm test` in `runner/`.
  App: `swift test` in `app/`.
- The protocol is the contract. Change `docs/protocol.md` first, then both
  sides, and keep both sides tolerant of unknown fields and event types.
- Only ever spawn the official `claude` (and later `codex`) binaries under
  Mike's own logins. Never read or copy OAuth tokens or Keychain credentials.
- Tests that hit a real model use the cheapest model, tiny prompts, a temp
  working folder and a temp runner data dir, never the real one.
- Never kill processes you didn't start; T3 Code runs the same CLIs.
- Screenshots: capture the app window only (by window id), never the full
  screen, and delete them when done unless they're for a PR.
- UI copy: plain words, no eyebrow or kicker labels, no em dashes.
- `docs/guide.md` is the user guide, and every thread's agent is pointed at
  it (`guideLine` in `runner/src/threadbear-mcp.ts`). Keep it true when a
  change alters what someone using the app sees or does.
- Every control gets a tooltip, with `.tip("…")` (SwiftUI) or `setTip` (AppKit).
  `.help` and `toolTip` never show in this app; TipsTests fails on them.
- Transcript files and fixtures made from real sessions are private: keep them
  out of git (`.fixtures/` is ignored).
- Errors go to Sentry (project `threadbear`, tag `component` mac, runner or
  ios) only from what Mike really runs: the installed release app
  (`app/Sources/Threadbear/CrashReporting.swift`), the installed runner's
  release on the real data dir (`runner/src/sentry.ts`) and App Store
  iPhone builds. Debug builds, dev runners, tests, sandboxes and scripted
  runs never report; keep it that way. `THREADBEAR_SENTRY=off` turns it off.
  Never add user text to what's sent. Convex reports through its own log
  stream, so convex/ has no Sentry.
- Mike's own repo: work goes to main once tests pass. A thread started in
  this repo has a worktree of its own and lands with `tb land` (below).
  Anywhere several threads share a checkout (the main one, a worktree made
  by hand), stage your own paths by name, never `git add -A`.
- A project can give Threadbear threads panels and action chips through
  `.threadbear/patches/*.ts` (docs/protocol.md, "Patches"). When Mike
  asks for a button or a panel for a project, write one of those there.
  A panel with an `items` function is a native list (rows, no page to
  serve); `.threadbear/patches/checks.ts` has one, Worktrees.
- After landing a change to the Mac app, don't ask Mike to Restart to
  Update or to check it for you: the app restarts onto the new build by
  itself once he leaves it idle. Call `wait_for_app_restart` with what to
  check and end the turn with needs "nothing". The runner messages this
  thread when the app is back on the new build (docs/protocol.md, "App
  restarts"); check it then yourself, with `tb export` of the thread and
  the scripted app (below), and ask him only for a judgement he has to make.
- Files and links an agent makes for Mike to look at belong in the
  thread's Highlights (the pin on the right-hand rail): use the `pin`
  tool, with `show: true` to open it in the side pane, rather than `open`.
  To put one of the app's own panels in front of him (this thread's
  Highlights or Patches, a patch panel, Usage, Updates), use
  `show_panel`: it opens the panel, or brings it forward where he has it,
  once he's looking at the thread (docs/protocol.md, "Showing panels").

## Working on Threadbear from inside Threadbear

Mike may be running this thread in Threadbear itself, through the installed
runner (`com.mikerosoft.threadbear.runner`). Then you have the `threadbear`
MCP tools (list, read, start, message, move and delete threads), and
`THREADBEAR_THREAD_ID` is set, so `tb self` and `tb status` show your thread
and the runner. Both are bound to this thread, and neither will delete,
interrupt, snooze or archive it. The runner puts its own `tb` on your PATH;
if `tb` isn't found (an older runner, or outside a thread), use
`runner/bin/tb`. `tb --help` lists the rest.

- `./check.sh` runs every check, about two and a half minutes (`--quick`:
  the runner's typecheck and unit tests; `--app`: the app's build and tests,
  for a change outside `runner/`). Nothing in it touches the live runner.
  A failure prints what failed and keeps the logs; it says where, so
  delete them when you're done.
- A thread started in this repo (from the app, `create_thread` or a
  schedule) gets a worktree of its own before its first turn:
  `<parent>/threadbear-threads/<id8>` on the branch `thread/<id8>`, made
  from main, with `node_modules` linked to the main checkout's
  (`worktree-setup.sh`). Your system prompt says where. Commit there. When
  the work is done and checked, `tb land` rebases it on main, runs
  `./check.sh --quick` and fast-forwards main in the main checkout
  (`--dry-run` first if you like; it never pushes). Mike's Land chip does
  the same. If it refuses, it says why and what to fix: commit your
  changes, sort out the conflicting files, fix the check, or wait for
  whoever has uncommitted changes in main's checkout. You can carry on
  after landing; the next `tb land` lands only what's new. Changing a
  `package.json`? Replace the link first: `rm runner/node_modules` (no
  trailing slash, so only the link goes), then `npm ci` there. The
  worktree is removed when the thread is archived with everything landed.
  docs/thread-worktrees.md has the details.
- A thread started somewhere else (like `~/dev/me/misc`) still makes its
  own worktree by hand, as another thread may be editing the main
  checkout: `git worktree add --detach <dir> main` (main is checked out in
  the main checkout), then `npm ci` in its `runner/` and
  `app/Tools/mock-runner/`, and merges to main itself.
- The live runner runs a release, a snapshot, so editing `runner/` doesn't
  change it. To try a runner change, start `runner/scripts/dev-runner.sh` in
  the background and use the `<dev home>/tb` it prints (a bare `tb` reaches
  the live runner unless `THREADBEAR_HOME` is set in that same command).
  Its threads start in `<dev home>/work` on claude-3 and claude-haiku-5-5
  (its `runner.json` defaults), from `tb` or a debug app's composer alike.
  Leave `--home` out, or keep it and any extra work folders under
  `$TMPDIR`: Agent Archive skips transcripts from there, but not from
  `/tmp`, so a try-out thread in `/tmp` ends up in Mike's archive.
  Stop it with the `kill <pid>` it prints, never
  `pkill`, and before you deploy or end your turn: the live runner's restart
  waits for it. Its temp data dir goes with it (`--keep` keeps it).
- To ship a runner change, merge it to main (`tb land` from a thread's
  own worktree). The live runner follows main
  by itself: within about five minutes it builds a release of main
  (`src/update.ts`, the deploy script's steps from its own clone) and
  restarts onto it once no thread is busy, which ends your turn if it's
  still running then (`tb status` shows the update's state and the
  pending restart; `tb logs` the result). To ship it sooner, or to get a
  resume into this thread afterwards, run from main
  `runner/scripts/deploy-runner.sh --dry-run` and
  `runner/scripts/deploy-runner.sh`, which ships HEAD of this checkout.
  When it says so, end your turn: the runner restarts once no thread is
  busy and resumes this thread so you can check the change (if it says it
  won't resume this thread, tell Mike in your reply)
  (`deploy-runner.sh --list` shows what's running). If the message that
  resumes you says your release isn't running, read `tb logs` before doing
  anything else. To undo a deploy, `deploy-runner.sh --rollback`; after an
  automatic crash rollback there's nothing to undo. A release that failed
  to build from main is said once in the app and in `tb status`, with its
  output in `<home>/runner/update.log`; fix it on main and it tries again.
- Until `deploy-runner.sh --list` shows releases, the live runner still runs
  from the main checkout and only Mike can switch it (one
  `install-runner.sh` from a terminal). Runner changes wait for him.
- Once launch.mjs supervises the runner (since Mike's `install-runner.sh`
  after 27 Oct), a restart with busy threads is a handover: the new release
  takes over at once, and busy threads (yours included) finish their turns
  on the old runner, then move across. `deploy-runner.sh` says which
  happened. Otherwise a restart waits for other threads' turns and
  background jobs (tests, builds, subagents; background ones for 30
  minutes at most). `tb status` shows what it's waiting for, or the old
  runner and what it's finishing; don't try to hurry either.
- The LaunchAgent's program is `~/Applications/Threadbear Runner.app`
  (`runner/launcher/`), a small app that runs `node launch.mjs` so macOS's
  privacy prompts say "Threadbear Runner", not "node". Releases never
  rebuild it: a change under `runner/launcher/` only ships when Mike runs
  `install-runner.sh` from a terminal. `tb status` and the app's Updates
  panel tell him once it's on main, but say so in your end_turn too.
- Never pass `--now`, run `install-runner.sh`, `tb restart` the live runner,
  `launchctl kickstart` it or stop its node process: each ends your own turn
  and stops other threads' work. If one is needed, finish and tell Mike the
  exact command. `tb restart` is for dev runners and sandboxes.
- Never run `app/restart.sh` or `app/install.sh` yourself: they replace and
  relaunch Mike's own app, in front of his work, and throw away whatever
  he's typed but not sent. To see an app change, use `app/Tools/dev-app.sh`
  (below). His installed app updates itself: a few minutes after `app/`
  changes on main it builds that commit in the background
  (`app/stage-update.sh`, from its own clone under
  `~/Library/Caches/Threadbear/update`, never the working tree) and swaps
  it in when he next quits or relaunches, from "Restart to Update" in the
  app menu, or by itself once nothing's typed and he isn't using the app
  (running threads don't hold it up; the runner keeps the turn). So merge an app change to main and tell him it's waiting;
  `~/Library/Logs/threadbear-update.log` has the build output if it
  doesn't turn up.
- `tb show <id>` reads a thread as text (`--tools` for results, each under
  its own call), `tb events <id> --from N --to M` a range of events by seq,
  `tb logs` the runner log, and `tb export <id>` copies a thread into
  `app/.fixtures/threads/<id>` so a rendering bug can be reproduced in a
  debug app (it prints the command). `tb <command> --help` explains one.
- `app/Tools/perf-run.sh` and `app/Tools/run-mock.sh` bring a window to the
  front of Mike's work, so ask him before running them.

## Seeing and driving the app

`app/Tools/dev-app.sh` runs a debug build in a temp bundle, against the
mock runner or a dev runner, with its window kept behind Mike's. Never use
`~/Applications/Threadbear.app` for this. Instances belong to the thread
and checkout that started them: without `--id`, a command means your
newest one, never another thread's, and `stop --all` stops only yours.
`start` prints the id; pass `--id` to every command once you have more
than one, and use `status` to see whose is whose.

- A UI change: `app/Tools/dev-app.sh start --mock` (the demo threads; add
  `--appearance light` for the other look), then drive it with
  `do '{"cmd":"open","id":"demo_upload"}' '{"cmd":"expand","row":"g:"}'`,
  read it with `dump` (rows with ids, kinds and heights, the composer and
  what a send would run on, the banner) and look at it with
  `shot <file.png>`. After an edit, `rebuild` restarts it on the new build
  with the same thread open. Look at the images before saying it works,
  then `stop`. An instance quits after an hour with no command. The
  commands are in `app/README.md` ("Seeing and driving it from a script").
- `shot` runs screencapture from your shell. If it says the image was drawn
  in-process (the screen is locked, or your shell has no Screen Recording
  permission), the sidebar's glass is a flat fill; the rest is right.
- A scripted app is never in front, so opening a thread doesn't mark it
  read until you send `{"cmd":"focus"}`.
- A bug in one of Mike's real threads: `tb export <id>`, then
  `app/Tools/dev-app.sh start --mock --fixtures app/.fixtures/threads/<id>`
  and `open` it. Exports are his private conversations: keep shots of them
  out of git and delete them when done.
- A runner change seen in the app: start `runner/scripts/dev-runner.sh`,
  then `dev-app.sh start --home <dev home>` (it prints that line). A
  message sent from that app's composer is a real turn; `dump` shows the
  model it would use.
- `dev-app.sh log` shows the app's own log (connection, RPC errors, the
  commands it ran). Mike can right-click a row for "Copy debug info" or use
  "Copy thread id" in the ... menu to point you at what he's seeing.
- For the full design set, `app/Tools/screenshots.sh <dir>` (`--only 11`
  for one scene).
