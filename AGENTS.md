# Agent guidance for threadbare

Threadbare is Mike's own agent app: a TypeScript runner daemon (`runner/`)
that drives the official Claude Code (and later Codex) CLIs, and a native
SwiftUI + AppKit Mac app (`app/`) that talks to it over the protocol in
`docs/protocol.md`. Read `docs/plan.md` and `docs/protocol.md` before changing
anything.

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
- Transcript files and fixtures made from real sessions are private: keep them
  out of git (`.fixtures/` is ignored).
- Mike's own repo: commit to main once tests pass.

## Working on Threadbare from inside Threadbare

Mike may be running this thread in Threadbare itself, through the installed
runner (`com.mikerosoft.threadbare.runner`). Then you have the `threadbare`
MCP tools (list, read, start, message, move and delete threads), and
`THREADBARE_THREAD_ID` is set, so `tb self` and `tb status` show your thread
and the runner. Both are bound to this thread, and neither will delete,
interrupt, snooze or archive it. The runner puts its own `tb` on your PATH;
if `tb` isn't found (an older runner, or outside a thread), use
`runner/bin/tb`. `tb --help` lists the rest.

- `./check.sh` runs every check (`--quick`: the runner's typecheck and unit
  tests). Nothing in it touches the live runner.
- The live runner runs a release, a snapshot, so editing `runner/` doesn't
  change it. To try a runner change, start `runner/scripts/dev-runner.sh` in
  the background and use the `<dev home>/tb` it prints (a bare `tb` reaches
  the live runner unless `THREADBARE_HOME` is set in that same command).
  Its threads start in `<dev home>/work` on claude-3; give them
  `--model claude-haiku-5-5`. Stop it with the `kill <pid>` it prints, never
  `pkill`, and before you deploy or end your turn: the live runner's restart
  waits for it.
- To ship a runner change, merge it to main, then from main run
  `runner/scripts/deploy-runner.sh --dry-run` and
  `runner/scripts/deploy-runner.sh`, which ships HEAD of this checkout.
  When it says so, end your turn: the runner restarts once no thread is
  busy and resumes this thread so you can check the change
  (`deploy-runner.sh --list` shows what's running). If the message that
  resumes you says your release isn't running, read `tb logs` before doing
  anything else. To undo a deploy, `deploy-runner.sh --rollback`; after an
  automatic crash rollback there's nothing to undo.
- Until `deploy-runner.sh --list` shows releases, the live runner still runs
  from the main checkout and only Mike can switch it (one
  `install-runner.sh` from a terminal). Runner changes wait for him.
- A restart waits for other threads' turns and background jobs (tests,
  builds, subagents; background ones for 30 minutes at most). `tb status`
  shows what it's waiting for; don't try to hurry it.
- Never pass `--now`, run `install-runner.sh`, `tb restart` the live runner,
  `launchctl kickstart` it or stop its node process: each ends your own turn
  and stops other threads' work. If one is needed, finish and tell Mike the
  exact command. `tb restart` is for dev runners and sandboxes.
- Rebuilding or restarting the app (`app/restart.sh`, `app/install.sh`) is
  safe: the runner keeps your turn going and the app reconnects.
- `tb show <id>` reads a thread as text, `tb logs` the runner log, and
  `tb export <id>` copies a thread into `app/.fixtures/threads/<id>` so a
  rendering bug can be reproduced against the mock runner (it prints the
  commands).
- `app/Tools/perf-run.sh` and `app/Tools/run-mock.sh` bring a window to the
  front of Mike's work, so ask him before running them.

## Seeing and driving the app

`app/Tools/dev-app.sh` runs a debug build in a temp bundle, against the
mock runner or a dev runner, with its window kept behind Mike's. Several
can run at once; each command takes `--id` (default: the last started).
Never use `~/Applications/Threadbare.app` for this.

- A UI change: `app/Tools/dev-app.sh start --mock` (the demo threads; add
  `--appearance light` for the other look), then drive it with
  `do '{"cmd":"open","id":"demo_upload"}' '{"cmd":"expand","row":"g:"}'`,
  read it with `dump` (rows with ids, kinds and heights, the composer, the
  banner) and look at it with `shot <file.png>`. Look at the images
  before saying it works, then `stop`. The commands are in `app/README.md`
  ("Seeing and driving it from a script").
- A bug in one of Mike's real threads: `tb export <id>`, then
  `app/Tools/dev-app.sh start --mock --fixtures app/.fixtures/threads/<id>`
  and `open` it. Exports are his private conversations: keep shots of them
  out of git and delete them when done.
- A runner change seen in the app: start `runner/scripts/dev-runner.sh`,
  then `dev-app.sh start --home <dev home>`.
- `dev-app.sh log` shows the app's own log (connection, RPC errors, the
  commands it ran). Mike can right-click a row for "Copy debug info" or use
  "Copy thread id" in the ... menu to point you at what he's seeing.
- For the full design set, `app/Tools/screenshots.sh <dir>` (`--only 11`
  for one scene).
