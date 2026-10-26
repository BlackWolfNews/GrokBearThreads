# Dev tools for working on Threadbare from inside Threadbare

Mike develops Threadbare from Threadbare threads, so the runner a thread
runs under is the thing being changed. Today that's fragile:

- The LaunchAgent runs `runner/src/main.ts` straight from the main
  checkout. Any merge to main changes the live runner the next time it
  restarts, and a runner that won't start takes every thread down,
  including the one that could fix it.
- Restarting the runner kills the turn that asked for it, and nothing
  carries on afterwards.
- An agent can't see the runner's state, read a thread as text, or
  reproduce a rendering bug from one of Mike's real threads without
  hand-made fixtures.

The built-in `threadbare` MCP server every session gets (create, update,
delete and move threads; `runner/src/threadbare-mcp.ts`) was built
separately and merged alongside this. Both are bound to the same thread
(see "Tools for agents" in `docs/protocol.md`). A `restart_runner` MCP
tool would be a thin wrapper over `runner.restart` below; it isn't built,
since from a thread runner changes go out through the deploy script.

## Phase 1: runner side

### 1. Runner releases

The live runner runs from a snapshot, never from a checkout. Layout under
the data dir (`<home>`, normally `~/Library/Application Support/Threadbare`):

```
<home>/runner/
  launch.mjs           the LaunchAgent's program: small, no dependencies
  releases/<id>/       src/, bin/, package.json, package-lock.json,
                       node_modules/ (production only), release.json
  current -> releases/<id>
  state.json           { current, previous, lastGood, boots, rolledBack? }
```

- **Release id:** `<UTC yyyymmddThhmmssZ>-<short commit>`, plus `-dirty`
  when built from uncommitted files. `release.json` is
  `{ id, commit, dirty, builtAt, node }`.
- **state.json** (atomic writes: temp file then rename):
  `{ "current": id, "previous": id|null, "lastGood": id|null,
  "boots": [{ "release": id, "at": iso }], "rolledBack": { "from", "to",
  "at" }? }`. Keep the last 20 boots.
- **launch.mjs** records a boot. If `current` has booted 3 times in the
  last 2 minutes without being marked good (since built: 10 minutes, with
  clean stops not counted and a 90 s startup watchdog, so planned restarts
  never trip it and a hang does; see `runner/README.md`), and `lastGood`
  is a different
  release that still exists, it points `current` at `lastGood`, records
  `rolledBack`, and logs it. Then it imports `current/src/main.ts`
  in-process (Node 24 runs TypeScript directly), so launchd's signals
  reach the runner as before.
- **main.ts** reports `RUNNER_VERSION` as `<package version>+<release id>`
  when a `release.json` sits next to its `src/`, else `+source`. Once it
  has been listening for 60 seconds it sets `lastGood` to its own release.
  If `state.rolledBack` is set and hasn't been reported, it sends a
  `runner.notice` warning at startup and to every client that says hello
  ("Release X kept crashing at startup, so the runner went back to Y."),
  then marks it reported.
- **`runner/scripts/deploy-runner.sh`**
  `[--skip-checks] [--allow-dirty] [--now [--force]] [--wait 30m]
  [--resume "text"] [--rollback] [--list] [--home DIR] [--label LABEL]
  [--dry-run]`:
  1. Checks: typecheck and unit tests with the pinned Node.
  2. Snapshot of the committed `runner/` at HEAD (refuse uncommitted
     changes under `runner/` unless `--allow-dirty`), then
     `npm ci --omit=dev` inside the release.
  3. Smoke test: start the release with a temp `THREADBARE_HOME` and
     `THREADBARE_PORT=0`, say hello over the WebSocket, check the version
     carries the new id, stop it.
  4. Activate: swap the `current` symlink atomically, record `previous`.
  5. Restart (section 2).
  6. Health: within 30 s of the restart, hello must report the new release
     id. If not, point `current` back at `previous`, restart, print the
     tail of the runner log and exit nonzero.
  7. Keep the newest 5 releases plus `lastGood`.
- **`install-runner.sh`** installs `launch.mjs`, builds the first release
  through `deploy-runner.sh`, and points the plist at
  `node <home>/runner/launch.mjs`. `--from-source` keeps today's
  run-from-the-checkout mode for debugging. `--home`, `--label` and
  `--port` allow a sandbox install next to the real one (the plist then
  sets `THREADBARE_HOME` and `THREADBARE_PORT`).

### 2. Restarting without killing the turn

- **Protocol** (update `docs/protocol.md` first):
  - `runner.restart { when?: "idle" | "now", resume?: { threadId, text },
    reason?: string }` returns `{ scheduled: boolean, waitingFor: string[] }`
    (`waitingFor`: the ids of threads keeping it from restarting).
  - `runner.status {}` returns `{ version, release?, pid, startedAt, home,
    liveClis, running: string[], pendingRestart?: { when, reason?,
    resumeThreadId?, requestedAt } }`.
  - `user.message` gains an optional `origin: "runner"` for messages the
    runner sends by itself. Old apps ignore it.
- **Idle** means no thread is running, starting, or waiting on an approval
  or a question. A pending restart is saved in `<home>/restart.json` so a
  crash doesn't lose it, and clients get a `runner.notice` ("The runner
  will restart when 2 threads finish."). A new `threads.send` while a
  restart is pending still works; the restart waits for that turn too.
- **When idle**, the runner shuts down the same way it does on SIGTERM and
  exits 0; launchd's KeepAlive starts it again. `when: "now"` does it
  straight away (threads mid-turn become `stopped`, as today).
- **On the next start**, if `restart.json` has a resume less than 15
  minutes old: append a `system.note` "Runner restarted: <old version> to
  <new version>" to that thread, then send the resume text as a new turn
  with `origin: "runner"`. At most 3 automatic resumes per thread per
  hour; past that, only the note. Delete `restart.json` once handled.
- **Environment:** every CLI the runner starts gets `THREADBARE_THREAD_ID`,
  `THREADBARE_HOME` and `THREADBARE_RUNNER_VERSION`.
- **deploy-runner.sh's restart step:** by default it calls
  `runner.restart { when: "idle", resume }`. Inside a thread
  (`THREADBARE_THREAD_ID` set) the resume defaults to "The runner restarted
  on release <id>. Check that your change works, then carry on." `--now`
  kickstarts the LaunchAgent, and is refused inside a thread unless
  `--force`. If the live runner is older and doesn't know `runner.restart`
  (method not found), poll until idle (`--wait`, default 30m) and then
  kickstart; inside a thread, print the command for Mike instead.

### 3. `tb` additions

- `tb status [--json]`: `runner.status`, readable.
- `tb self [--json]`: the calling thread, from `THREADBARE_THREAD_ID`.
- `tb restart [--now] [--resume "text"] [--reason "text"]`.
- `tb show <id> [--last N] [--tools]`: the thread as plain text: user and
  assistant messages, one line per tool call (with `--tools`, results
  too), approvals, notes, turn footers. A call's diff, approval and result
  go under it, so parallel calls' results don't land under the wrong one.
- `tb events <id> [--from N] [--to M] [--json]`: events by seq, each line
  starting with its seq (Copy debug info gives the command). Every tb
  command refuses flags it doesn't read, and `tb <command> --help` shows
  just that one.
- `tb logs [-f] [-n 200] [--thread ID]`: the runner log, optionally
  filtered to one thread.
- `tb export <id> [--out DIR]`: `thread.json`, `events.ndjson` and
  `media/` in the mock runner's fixture format, by default under
  `app/.fixtures/threads/<id>` (private and gitignored), so a rendering bug
  in one of Mike's threads can be reproduced against the mock runner.
- `tb rpc <method> [json]`: a raw call, printing the result.

### 4. Dev runner and one check command

- `runner/scripts/dev-runner.sh [--home DIR] [--port N]`: runs the working
  tree's runner in the foreground on a temp data dir (refuses the real
  one) and prints the `<home>/tb` for `tb` and the `dev-app.sh start
  --home` line for the app. A new data dir's `runner.json` defaults threads
  to `<home>/work`, claude-3 and claude-haiku-5-5 (`defaults.model`, which
  the runner applies to a `threads.create` with no model).
- `./check.sh [--quick | --app] [--e2e] [--shots DIR]` at the repo root:
  runner typecheck, unit tests and deploy tests, app `swift build` and
  `swift test` (with the mock runner's packages installed and its tests
  required). `--app` is the app's part alone. `--e2e`
  adds the runner's real-model e2e (cheapest model, temp dirs); `--shots`
  runs `app/Tools/screenshots.sh`. One line per step, nonzero exit if
  anything failed, pinned Node 24.

### 5. Docs

`AGENTS.md` ("Working on Threadbare from inside Threadbare", kept short),
`runner/README.md`, `docs/protocol.md`.

## Phase 2: app side

Built on 2026-10-27. How to use it is in `app/README.md` ("Seeing and
driving it from a script") and in AGENTS.md ("Seeing and driving the app").

- `app/Tools/dev-app.sh start [--mock [--fixtures DIR]...] [--home DIR]
  [--appearance light|dark] [--size WxH] [--id NAME]`, then `do
  '<json>'...`, `shot <file>`, `dump [--json]`, `rebuild`, `log`,
  `stop [--all | --everyone]`, `status`. Each instance is a debug build in
  a temp bundle with its own bundle id (its own settings), data folder,
  automation notification name and pasteboard (`--automation-id`), so
  several run at once. Instances belong to the thread and checkout that
  started them: commands take `--id`, defaulting to the caller's newest,
  never another thread's, and `stop --all` stops only the caller's. An
  instance quits after an hour with no command and its mock exits with it;
  `start` and `status` clean up after ones that quit. `shot` runs
  screencapture from the caller's shell (the temp bundle has no Screen
  Recording permission) and falls back to the app's own drawing. It
  launches with `open -g` and the app orders its window to the back as soon
  as it exists. `do` tags each command with a request id and waits for that
  result line; an error result or a timeout exits 1. `--fixtures` takes
  `tb export` folders; `--home` a dev runner's data dir (never the live
  one). `stop` quits the app, stops its mock and deletes the bundle, the
  data, the logs and the bundle id's preferences.
- The scripted app refuses the installed runner's data folder unless
  `--automation-allow-live`, never saves window sizes, and has `focus`
  (counts as looking, so threads get marked read) and `window` (its id for
  screencapture); `options` refuses unknown keys and reports what's set,
  and `dump` shows what a send from the composer would run on.
- Automation commands added or rounded out: `open` (waits for the rows),
  `screenshot` (in-process when the screen is locked), `dump` (sidebar
  rows by section; transcript rows with id, kind, height, open or not, on
  screen or not, an excerpt; selection, composer text, banner), `hover`
  (sidebar or transcript rows), `expand` and `collapse` (groups, tools,
  changed files, whole diffs), `scroll`, `appearance`, `resize`,
  `waitFor` (row, kind, status, text, banner, connection, ready, with
  `not` and a timeout), `new`, `type`, `send`, `menu` (a row's context menu,
  or one of its items), `debug-info`, `copy-thread-id`, `clipboard` and
  `mock` (`mock.*` methods only). Still debug builds only.
- The app's own log (connection, RPC errors, runner notices, automation
  commands) goes to the unified log, and with `--automation` to a file
  beside the automation log too (`--app-log`); `dev-app.sh log` tails it.
- A pending runner restart is a quiet grey line under the toolbar ("The
  runner will restart when 2 threads finish.", or "when 1 thread finishes
  and you answer 2." when some wait on Mike; the threads in its tooltip),
  from `runner.notice` and `runner.status`; while the runner is down it
  says "The runner is restarting. Reconnecting…" with a spinner and the
  app retries every half second. A `user.message` with `origin: "runner"`
  is a centred note, "Sent by the runner after it restarted" over its text.
  The mock has `runner.status`, `mock.restartPending` and `mock.restart`,
  and `Tools/screenshots.sh --only 11` shoots all three states.
- "Copy debug info" on every transcript row (thread, row, kind, turn, the
  seqs of the events it came from, the runner's version) and "Copy thread
  id" in the ... menu. A scripted app copies to its own pasteboard.
- "Start runner" only shows when the app uses the installed runner's data
  folder, so a debug app against the mock or a dev runner can't kickstart
  the live one.

## Safety during the build

- Nothing touches the live runner, its LaunchAgent
  (`com.mikerosoft.threadbare.runner`), `~/Library/Application
  Support/Threadbare` or `~/Applications/Threadbare.app`. Trials use a temp
  `--home`, a free port and a test label such as
  `com.mikerosoft.threadbare.runner.devtest`, booted out and removed
  afterwards.
- The real switch to releases happens after review, when no thread is
  running, through the deferred restart itself.
