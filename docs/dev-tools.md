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

Another thread (branch `runner-tools`) is building the built-in `threadbare`
MCP server that every session gets: create, update, delete and move
threads. This work doesn't touch that. Once both land, a `restart_runner`
MCP tool is a thin wrapper over `runner.restart` below.

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
  last 2 minutes without being marked good, and `lastGood` is a different
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
  too), approvals, notes, turn footers.
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
  one) and prints the `THREADBARE_HOME=...` line for `tb` and the
  `--data-dir` for the app.
- `./check.sh [--quick] [--e2e] [--shots DIR]` at the repo root: runner
  typecheck and unit tests, app `swift build` and `swift test`. `--e2e`
  adds the runner's real-model e2e (cheapest model, temp dirs); `--shots`
  runs `app/Tools/screenshots.sh`. One line per step, nonzero exit if
  anything failed, pinned Node 24.

### 5. Docs

`AGENTS.md` ("Working on Threadbare from inside Threadbare", kept short),
`runner/README.md`, `docs/protocol.md`.

## Phase 2: app side (after the design pass lands)

- `app/Tools/dev-app.sh start [--mock [--fixtures DIR]] [--home DIR]`,
  `do '<json>'...`, `shot <file>`, `dump`, `stop`: a debug app in a temp
  bundle with `--automation`, its window kept behind Mike's, against the
  mock runner, a fixture export or a dev runner. `do` waits for each
  command's result and prints it.
- Automation commands: `screenshot`, `dump` (sidebar rows and transcript
  rows as JSON: id, kind, height, expanded, text excerpt), `hover`,
  `expand`, `collapse`, `scroll`, `appearance`, `resize`, `open`,
  `waitFor`.
- The app shows a pending runner restart as a quiet banner, and marks
  `origin: "runner"` messages as sent by the runner after a restart.
- "Copy debug info" on transcript rows (thread id, row id, event seqs) and
  "Copy thread id" in the ... menu, so Mike can point an agent at a row.

## Safety during the build

- Nothing touches the live runner, its LaunchAgent
  (`com.mikerosoft.threadbare.runner`), `~/Library/Application
  Support/Threadbare` or `~/Applications/Threadbare.app`. Trials use a temp
  `--home`, a free port and a test label such as
  `com.mikerosoft.threadbare.runner.devtest`, booted out and removed
  afterwards.
- The real switch to releases happens after review, when no thread is
  running, through the deferred restart itself.
