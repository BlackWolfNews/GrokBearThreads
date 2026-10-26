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
runner (`com.mikerosoft.threadbare.runner`). Then `THREADBARE_THREAD_ID` is
set, and `runner/bin/tb self` and `tb status` show your thread and the
runner. `runner/bin/tb --help` lists the rest.

- `./check.sh` runs every check (`--quick`: the runner's typecheck and unit
  tests). Nothing in it touches the live runner.
- The live runner runs a release, a snapshot, so editing `runner/` doesn't
  change it. To try a runner change, start `runner/scripts/dev-runner.sh` in
  the background and use the `<dev home>/tb` it prints (a bare `tb` reaches
  the live runner unless `THREADBARE_HOME` is set in that same command).
  Stop it with the `kill <pid>` it prints, never `pkill`.
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
  builds, subagents). `tb status` shows what it's waiting for; don't try to
  hurry it.
- Never pass `--now`, run `install-runner.sh`, `launchctl kickstart` the
  runner or stop its node process: each ends your own turn and stops other
  threads' work. If one is needed, finish and tell Mike the exact command.
  `tb restart` is for dev runners and sandboxes.
- Rebuilding or restarting the app (`app/restart.sh`, `app/install.sh`) is
  safe: the runner keeps your turn going and the app reconnects.
- `tb show <id>` reads a thread as text, `tb logs` the runner log, and
  `tb export <id>` copies a thread into `app/.fixtures/` so a rendering bug
  can be reproduced against the mock runner (it prints the command).
- Check app changes with `app/Tools/screenshots.sh <dir>`: a debug build
  against the mock runner, in a temp folder, with the window kept behind
  whatever Mike is working in. Look at the images before saying it works.
- `app/Tools/perf-run.sh` brings its window to the front for about a minute,
  so ask Mike before running it.
