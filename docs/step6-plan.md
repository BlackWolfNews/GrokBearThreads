# Step 6: a second runner (Bruce)

Draft, 29 Oct 2026. Nothing here is built. It follows `docs/plan.md`
("Build order") and the multi-runner notes in `docs/convex-backend.md`.

The plan said Tinker Desk. On 29 Oct Mike moved it to Bruce: Tinker Desk is
kept for testing clean installs of Threadbear as a new user would, and a
second runner there would muddy those tests.

## Why

Two things Mike wants that one runner on the laptop can't give:

- **Work that doesn't need the laptop.** Scheduled jobs (the Slack, Gmail and
  Calendar ones in `~/dev/me/misc/schedules`) only fire while the M5 is awake
  (protocol.md, Schedules, "Late runs"). Bruce never sleeps
  (`pmset sleep 0`).
- **Work off the M5.** A thread that runs on another Mac leaves the laptop
  quick. Bruce has 8 GB, so this means a few threads at a time, not heavy
  builds: those stay on Tinker Desk by hand, as now.

## What already works for several runners

- **Convex.** Every row (threads, messages, projects, schedules, accounts)
  carries `runnerId`. The `runners` table has each runner's name, version and
  heartbeat. Phone commands go to the thread's runner, and a new thread names
  one or goes to "any" (the newest one online). The phone needs nothing new
  beyond a machine label on rows.
- **Runner identity.** `ensureRunnerId` gives each data dir a stable id, and
  the name defaults to the hostname (`defaultRunnerName`), so Bruce would
  show as "bruce".
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
- **Accounts and pools** are per runner. Bruce has one Claude login
  (mike.cann@gmail.com), Codex installed and signed in, and no Token Stats
  accounts folder.

## Runs on: picking a runner

Mike, 29 Oct: every thread and every schedule has a runner set from the
start, chosen by Mike or by the agent. Nothing guesses.

- **Mike picks** with a **Runs on** picker, the same one on the composer
  for new threads and in the schedule editor: this Mac, Bruce, later a
  cloud sandbox. From the Mac app it defaults to this Mac; the default is
  a setting. The phone and website use that setting too.
- **Agents pick** through the threadbear tools: `create_thread` and
  `schedule_message` take an optional runner. Without one, the new thread
  or schedule goes on **the runner the agent's own thread is on**.
- **A schedule that sends into an existing thread** runs on that thread's
  runner, so it has no picker.
- **Work stays where it is.** A thread keeps its runner until Mike or its
  agent moves it on purpose (see Later).
- A runner is only offered if it can do the job: the folder exists on that
  machine and it has a login for the thread's provider.

## Part 1: schedules in Convex

Decided 29 Oct (Mike): schedules live in Convex, not in each runner's
`schedules.json`, so they don't depend on any one runner being up, and no
runner forwards schedules to another. It's the one place the 27 Oct
decision (`docs/convex-backend.md`, shape A: the runner owns state, Convex
mirrors it) flips: for schedules Convex owns them and runners follow.

- **Table** `schedules` in Convex is the source of truth (today it's only a
  mirror for the phone). Each row keeps today's `Schedule` fields plus
  `runnerId`. The current `schedules.json` is moved in once, onto the M5's
  runner.
- **The clock is the runner's own timer; Convex decides who sends.** As
  built (29 Oct), each runner checks its own schedules as before, and
  before sending a due run takes it with `sync:claimSchedule`, a mutation,
  so a run starts exactly once. That matters even with one runner per
  schedule: during a handover two runner processes share a `runnerId`.
  The claim is a lease: if the run isn't recorded within 2 minutes, it can
  be taken again. The draft had Convex's `scheduler.runAt` as the clock,
  but with every schedule on a named runner nothing can run while that
  runner is off anyway, so a Convex clock added moving parts and no
  behaviour. It's worth adding with "Any" (below), if that comes.
- **Runners subscribe** to the whole table (`sync:schedules`), so the Mac
  app's list shows every runner's schedules with the runner's name, and a
  "Run now" on another runner's schedule is a request
  (`sync:requestScheduleRun`) its runner picks up.
- **When its runner is off**, the run waits, then happens once when the
  runner is back, as late runs do today.
- **The skip rule stays**: a repeating schedule whose last thread is still
  running or waiting on Mike skips a run. Convex can see that from the
  mirrored thread rows.
- **The Mac app doesn't read Convex.** It keeps asking its runner
  (`schedules.list`, `schedules.create`, ...), and the runner reads and
  writes Convex. The same goes for agents' `schedule_message` tools and
  `tb`. The phone and website can make and edit schedules directly.
- **Offline**: with no internet nothing fires, even on this Mac. Mike
  accepted that: Convex is assumed to be up.

Until part 2, a thread a schedule starts on Bruce shows on the phone and
the website, not in the Mac app.

## Part 2: Bruce's threads in the Mac app

The M5's runner connects to Bruce's runner over Tailscale, as a
*remote peer*, the way a primary connects to a draining runner today. The
Mac app keeps its one socket:

- `threads.list`, `threads.search` and `hello` include the remote runner's
  threads, each with a `runner: { id, name }` so the sidebar can label it
  (only when it isn't this Mac's).
- Requests about a remote thread (`threads.send`, `threads.events`,
  `threads.subscribe`, `approvals.respond`, ...) go to its runner, and its
  events come back through, as for a kept thread in a handover.
- `threads.create` takes an optional `runnerId`: the Runs on picker, as a
  small machine chip on the composer beside folder, account and model.
- Files: a new `files.read { path, maxBytes? }` (and an image variant with
  a thumbnail size) that the local runner answers itself or forwards. The
  app fetches remote images, blobs and linked files through it and caches
  them, rather than opening the path.
- Folders: `folders.list` on the remote runner for the picker; recent
  folders are per runner.

Proposed: the M5's runner fronts Bruce's (above). Not decided; Mike wanted
to talk it through. Why this shape rather than the others:

- **The app opening a socket per runner** works too, but every view that
  holds `client` would learn about several, and every list would merge in
  Swift. The runner already merges for handovers.
- **The app reading remote threads from Convex** is ruled out by the
  project notes: no always-on Convex subscriptions behind the sidebar (the
  Agent Archive cost pattern).

What it costs: Bruce's threads only show on the Mac while the M5's runner
can reach it. The phone sees both through Convex either way.

## Installing on Bruce

Checked 29 Oct over SSH:

- macOS 26.5, M1, **8 GB**. It already runs the Agent Archive server
  (about 1 GB), the Connectors gateway, Sammy Cam's Convex backend and
  Cannvas media, and had 2 GB of swap in use. The runner itself is small;
  each live Claude or Codex CLI adds a few hundred MB, so keep its
  idle-release short and expect a few threads at a time.
- Desktop logged in as `bruce`, `pmset sleep 0`, 67 GB free.
- Node 24.22.1 in nvm, Claude Code at `~/.local/bin/claude`, Codex in the
  nvm bin, both signed in.
- Same release, its own data dir, LaunchAgent and Runner.app, installed by
  `install-runner.sh` over SSH. Runner.app gets its own privacy grants, so
  the Node path problem Bruce's other services had after the 26 Oct Node
  upgrade (file access stored per binary path) shouldn't apply; check it
  under launchd, not over SSH, anyway.
- Bruce's pf lockdown blocks a fixed list of ports on the LAN, so a new
  port isn't covered by it. The runner listens on its Tailscale address
  (and 127.0.0.1) only, with its own peer token copied to the M5 once.
- Sync uses the same Convex deployment and `RUNNER_KEY` as the M5.
- Updates follow `main` like the M5's (`docs/setup-and-updates.md`), so it
  needs read access to the repo.

## Questions for Mike

1. Part 2's shape: the M5's runner fronts Bruce's, one socket for the app?
2. Which Claude login goes on Bruce? Today it's mike.cann@gmail.com.

Decided 29 Oct: schedules first, held in Convex (part 1). Every thread and
schedule has its runner set by Mike or the agent: this Mac by default in
the app, the agent's own runner for what an agent makes.

## Later

- **Any runner** for schedules that don't mind where they run: no runner
  set, and the first runner that can do it claims it. The claim already
  makes this safe; Mike thinks it could be interesting but not at first.
- **Smarter runner choice**, so Mike doesn't always have to pick. Not at
  first.
- **Moving a thread to another runner**, by Mike or its agent
  (`move_thread` with a runner), with a handoff note as account moves do
  (`docs/pools-plan.md`), when the folder exists on both.
- Cloud sandboxes: a runner in a throwaway VM is a remote peer like Bruce,
  plus making and destroying the VM.
