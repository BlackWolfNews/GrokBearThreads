# Step 6: Tinker Desk as a second runner

Draft, 29 Oct 2026. Nothing here is built. It follows `docs/plan.md`
("Build order") and the multi-runner notes in `docs/convex-backend.md`.

## Why

Two things Mike wants that one runner on the laptop can't give:

- **Work that doesn't need the laptop.** Scheduled jobs (the Slack, Gmail and
  Calendar ones in `~/dev/me/misc/schedules`) only fire while the M5 is awake
  (protocol.md, Schedules, "Late runs"). Tinker Desk never sleeps
  (`pmset sleep 0`).
- **Heavy work off the M5.** Long e2e and simulator suites already go to
  Tinker Desk by hand over SSH. A thread that runs there does the same thing
  without the SSH dance, and the M5 stays quick.

## What already works for several runners

- **Convex.** Every row (threads, messages, projects, schedules, accounts)
  carries `runnerId`. The `runners` table has each runner's name, version and
  heartbeat. Phone commands go to the thread's runner, and a new thread names
  one or goes to "any" (the newest one online). The phone needs nothing new
  beyond a machine label on rows.
- **Runner identity.** `ensureRunnerId` gives each data dir a stable id, and
  the name defaults to the hostname (`defaultRunnerName`), so Tinker Desk
  would show as "tinker-desk".
- **Talking to another runner.** Handovers (protocol.md, "Handovers")
  already have the primary runner forward requests about some threads to
  another runner and pass its events back (`Peers`, `ThreadRouter` and
  `scheduleRouter` in `runner/src/handover.ts`). Clients don't know.

## What assumes one Mac

The Mac app has one socket, to `ws://127.0.0.1:<port>/rpc`, with the token
from the local data dir (`RunnerConfig.endpoint`). Beyond the socket, a
remote thread breaks wherever the app treats a path as a file on this Mac:

- **Images.** `ImageRef.path` is "an absolute path on this Mac". Pasted
  images go into the local runner's `inbox/`.
- **Tool output over 64 KB** (`blobPath`), file links in the transcript,
  diffs opened in the panel, text files in the side pane.
- **Folders.** The composer's folder picker and `cwd` checks read this
  Mac's disk. Patches (`appliesTo`) look in this Mac's folders.
- **Accounts and pools** are per runner. Tinker Desk has one Claude login
  (mike.cann@gmail.com), a Codex login but no Codex CLI, and no Token Stats
  accounts folder.

## Proposed shape: the local runner fronts the remote one

The M5's runner connects to Tinker Desk's runner over Tailscale, as a
*remote peer*, the way a primary connects to a draining runner today. The
Mac app keeps its one socket:

- `threads.list`, `threads.search` and `hello` include the remote runner's
  threads, each with a `runner: { id, name }` so the sidebar can label it
  (only when it isn't this Mac's).
- Requests about a remote thread (`threads.send`, `threads.events`,
  `threads.subscribe`, `approvals.respond`, ...) go to its runner, and its
  events come back through, as for a kept thread in a handover.
- `threads.create` and `schedules.create` take an optional `runnerId`. The
  composer gets a small machine chip beside folder, account and model, and
  the schedule editor a "Runs on" picker, both defaulting to this Mac.
- `schedules.list` merges both runners' lists. A schedule lives on its own
  runner, so one made for Tinker Desk fires with the laptop shut.
- Files: a new `files.read { path, maxBytes? }` (and an image variant with
  a thumbnail size) that the local runner answers itself or forwards. The
  app fetches remote images, blobs and linked files through it and caches
  them, rather than opening the path.
- Folders: `folders.list` on the remote runner for the picker; recent
  folders are per runner.

Why this shape rather than the others:

- **The app opening a socket per runner** works too, but every view that
  holds `client` would learn about several, and every list would merge in
  Swift. The runner already merges for handovers.
- **The app reading remote threads from Convex** is ruled out by the
  project notes: no always-on Convex subscriptions behind the sidebar (the
  Agent Archive cost pattern).

What it costs: Tinker Desk's threads only show on the Mac while the M5's
runner can reach it. The phone sees both through Convex either way.

## Installing on Tinker Desk

- Same release, its own data dir, LaunchAgent and Runner.app, installed by
  `install-runner.sh` over SSH. The desktop is logged in (`mikeysee`), so a
  LaunchAgent runs. After a reboot it waits for that login, as the gha-wake
  agent does today (auto-login is off, and was left off on purpose).
- Node 24.22.1 is already there. Claude Code is at `~/.local/bin/claude`.
  Codex needs `npm install -g @openai/codex`.
- It listens on its Tailscale address as well as 127.0.0.1, with its own
  peer token (copied to the M5 once). Nothing on the LAN.
- Sync uses the same Convex deployment and `RUNNER_KEY` as the M5.
- Updates follow `main` like the M5's (`docs/setup-and-updates.md`), so it
  needs read access to the repo.
- 53 GB free on a 460 GB disk, shared with Colima, simulators and the
  Windows VM. Worktrees for its threads go under its own data dir.

## Questions for Mike

1. Is the shape right: the M5's runner fronts Tinker Desk's, one socket for
   the app?
2. Which Claude login goes on Tinker Desk? Today it's mike.cann@gmail.com
   (the one `claude remote-control` uses there).
3. What first: just schedules (smaller, since a schedule's thread can stay
   on Tinker Desk and be read on the phone), or remote threads in the Mac
   app too?

## Later

- "Any awake runner" for schedules: Convex notices the owning runner's
  heartbeat is stale and sends a due run to another runner
  (`docs/convex-backend.md`, Schedules). Needs a rule so a run never fires
  twice.
- Moving a thread between machines, with a handoff note as account moves
  do (`docs/pools-plan.md`), when the folder exists on both.
- Cloud sandboxes: a runner in a throwaway VM is a remote peer like Tinker
  Desk, plus making and destroying the VM.
