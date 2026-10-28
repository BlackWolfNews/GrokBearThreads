# Setup, updates, the phone and Tailscale (proposal)

28 Oct 2026, thread 66935d23. A proposal for Mike to react to, nothing built yet.

What Mike asked for: setting up Threadbear has you create a Convex deployment
"where everything goes"; a careful think about how updates work and how the iPhone app
fits; Tailscale as the default way things talk to each other; and defaults that suit
Mike, since it's his app first and other people patch their own copy.

## 1. Where things stand

How it works today (file references are in the research notes at the bottom):

- **Install** is two hand-run scripts: `app/install.sh` builds the Mac app, and
  `runner/scripts/install-runner.sh` installs the runner's LaunchAgent. Node is pinned
  to Mike's nvm path, and some defaults are his (`~/dev/me/misc`, `claude-2` for
  Convex work, Token Stats for account limits).
- **Updates** follow the local `main` branch of the checkout. The runner and the Mac app
  both notice when `main` moves and rebuild themselves, and the runner rolls back to its
  last good release after 3 crashes in 10 minutes. Nothing ever fetches from GitHub, so
  a commit on Mike's Mac ships to Mike's Mac, and that's all.
- **Convex** is a cloud deployment in Mike's account, set up by hand in about 8 steps
  (project, `.env.local`, deploy, make a key, `RUNNER_KEY`, `sync.url`, phone token, the
  APNs keys). Functions are deployed by hand and nothing checks that the runner and the
  deployment are on the same version.
- **The phone** only talks to Convex. Pairing is a script that draws a QR code. The app
  only accepts `*.convex.cloud` and `*.convex.site` addresses. Push uses Mike's Apple
  key, which lives in his deployment.
- **The runner** only listens on `127.0.0.1`. Nothing uses Tailscale yet.

## 2. The proposal in one go

Threadbear runs its own Convex backend on your own machine (Convex's open source
self-hosted backend), and Tailscale is how everything else reaches it: your phone, your
browser and a second runner. The backend holds everything, not just the 20-message
mirror, because there's no cloud bill or size limit to worry about. Setup is one
command. Updates are your own `main` as today, plus a way to bring in Mike's changes
that an agent does for you and you approve. There's one App Store iPhone app for
everyone, which pairs with any Threadbear backend and gets notifications through a
small relay Mike runs.

The parts, with the choices that need Mike:

### 2.1 The backend: self-hosted Convex over Tailscale

**What:** the Convex backend binary (what `npx convex dev --local` already runs for the
e2e tests) runs as a LaunchAgent next to the runner, keeping its data under
`~/Library/Application Support/Threadbear/convex/`. `tailscale serve` puts it on the
Mac's tailnet name with HTTPS, e.g. `https://m5-mike.tail9ef766.ts.net:8443` for the
API and `:8444` for HTTP actions and the website. Only devices on your tailnet can reach
it.

**Why this over Convex's cloud (what we have today):**

| | Self-hosted on your tailnet | Convex cloud (today) |
|---|---|---|
| What can go there | Everything: full transcripts, tool output, images | A thin mirror (newest 20 messages), because of cost |
| Cost | Nothing | Usage on your Convex plan (Agent Archive moved off it for this reason) |
| Privacy | Never leaves your machines | Text sits in Convex's cloud |
| Needs | Tailscale on the phone | A Convex account |
| When the Mac is asleep | Unreachable. But agents aren't running then either, so you only lose reading old threads | Still readable, and messages queue |
| Who looks after it | Threadbear (backend upgrades and backups are part of updates) | Convex |

The asleep row is the main cost, and it mostly disappears if the backend lives on an
always-on machine. So the default is "the same Mac", with a setup option to put it on
another tailnet machine. For Mike that's Bruce, which is always on, already on the
tailnet, and already where Agent Archive lives.

**What it changes:** the runner writes everything to the backend instead of a thin
mirror, so the phone and the website can show whole transcripts, images included.
Later, the Mac app could read from it too, which is the step that would make a second
Mac or Tinker Desk feel like one app, but that isn't needed to start.

**Fallback:** Convex cloud stays possible for anyone who doesn't want Tailscale. It's the
same functions with a different URL, so it's a setting rather than a fork.

**To check in a spike first:** that the self-hosted backend runs the static-hosting
component, that `tailscale serve` with two ports is fine on macOS, how the backend
binary is upgraded, and how big a month of full transcripts gets (the 27 Oct
measurement was about 10 GB a month including images, so images may want to stay as
files the backend links to).

### 2.2 Setup: one command

`./threadbear setup` from a clone, written so an agent could also run it:

1. Checks the basics: Xcode command line tools, Tailscale installed and logged in,
   Claude Code or Codex logged in. Downloads its own Node into the data folder rather
   than relying on nvm.
2. Starts the backend (2.1), makes its admin key and the runner's key, deploys the
   functions and the website, and writes `runner.json`. No Convex account, no
   `.env.local`, no hand-set env vars.
3. Builds and installs the runner and the Mac app (today's two scripts, folded together).
4. Opens the Mac app, whose first screen shows a pairing QR code for the phone
   (Settings › Phone, replacing `pair-qr.swift`).

Mike's own defaults stay defaults (misc as the default folder and so on), but move into
`runner.json` with a first-run question or two, so they aren't baked into the code.

### 2.3 Updates: your main, plus Mike's changes when you ask

Everyone has their own fork. `origin` is theirs, and setup adds `upstream` pointing at
`mikecann/threadbear`. For Mike they're the same repo.

- **Your own changes ship as they do today.** Commit to `main` (or ask a thread to) and
  the runner and the app rebuild themselves. Patches you write in `.threadbear/patches/`
  need no fork at all.
- **Mike's changes come in when you say so.** The runner fetches `upstream` every few
  hours. When there's something new, the app shows "12 new changes from Mike" with what
  they are. "Bring them in" starts a thread that merges upstream into your `main`, sorts
  out clashes with your own changes, runs the checks, and asks before it lands. It never
  happens silently, because a merge can quietly undo something you changed on purpose.
- **Each release deploys its backend first.** The release pipeline gains a step: deploy
  the Convex functions (and the website) to your backend, then restart the runner. Today
  nothing does this, so a runner can quietly get ahead of its backend.
- **Changes stay compatible both ways.** For a while an older runner, a newer backend and
  a phone app from the App Store all coexist. Schema changes widen first and narrow
  later. The backend reports an `apiVersion` and the phone checks it.

### 2.4 The iPhone app: one app for everyone

People won't build their own phone app, as Mike said, so there's one App Store app and
everything about it has to work with anyone's backend.

- **Pairing:** scan the QR code from the Mac app. It carries the backend's address and a
  token. The app allows `*.ts.net` addresses (and the Convex cloud ones for the
  fallback).
- **Connecting:** with the default setup, the phone needs Tailscale on. If it can't
  reach the backend, it says so and offers to open Tailscale.
- **A stable phone API:** `convex/phone.ts` is a contract between your backend and Mike's
  App Store app. It gets a version number; forks can add to it but shouldn't change
  what's there. The app shows "update Threadbear on your Mac" when a backend is too old,
  and the backend can say which app versions it needs.
- **Notifications:** Apple only accepts pushes for Mike's app signed with Mike's key, so
  a backend that isn't Mike's can't send them itself. The proposal is a small push
  relay that Mike runs as a Cloudflare Worker holding his key. Backends send it a device
  token and an **encrypted** message; the phone decrypts it with a key it got at pairing
  (a Notification Service Extension), so the relay only ever sees gibberish. Mike's own
  backend uses the relay too, so his setup is the same as everyone's.

### 2.5 Tailscale by default, everywhere

- **The phone and the backend:** as above.
- **Thread links:** the website lives on the backend, so a thread's link becomes
  `https://<mac>.<tailnet>.ts.net:8444/t/<id>`. It opens on any of your devices and
  nowhere else. Tailscale can also tell the backend who's asking (`tailscale serve`
  passes the tailnet login in a header), so on your own tailnet the browser might not
  need a sign-in token at all.
- **A second runner:** Tinker Desk (plan step 6) runs its own runner and writes to the
  same backend over the tailnet. Its threads show up on the phone and the website
  straight away, and later in the Mac app.
- **The Mac app and a remote runner:** later, the Mac app could talk to a runner on
  another tailnet machine directly, so Tinker Desk's threads are steerable from the
  laptop.

## 3. What Mike needs to decide

1. **The backend:** self-hosted Convex on the tailnet as the default (recommended), or
   keep Convex cloud as the default?
2. **Where Mike's lives:** on Bruce, so the phone works when the laptop is shut
   (recommended), or on the laptop like everyone else's default?
3. **"Everything goes there":** whole transcripts including tool output, with images
   kept as files the backend links to (recommended), or images in the backend too?
4. **Push relay:** OK to run one for everyone, with encrypted messages (recommended)?
5. **Bringing in Mike's changes:** an agent thread you approve each time (recommended),
   or something more automatic?

## 4. A rough order to build it in

1. Spike: the self-hosted backend under launchd, behind `tailscale serve`, with the
   current functions, the website and a phone paired to it (pairing allows `*.ts.net`).
   This answers the open questions in 2.1.
2. Move Mike over: backend on Bruce (or the laptop), runner writing to it, phone
   re-paired. Keep Convex cloud running until it's settled, then turn it off.
3. The release pipeline deploys the backend; `apiVersion` in the backend and the phone.
4. Write everything, not just the mirror. The phone and the website show full threads.
5. Push relay with encrypted messages, and the phone's notification extension.
6. `./threadbear setup`, the pairing QR code in the Mac app, Mike's defaults moved into
   `runner.json`.
7. Upstream updates: fetch, "new changes from Mike", the merge thread.
8. Tinker Desk as a second runner on the same backend.

Steps 1 to 4 are useful to Mike straight away. 5 to 7 are what make it installable by
other people, and the landing page's promise ("Threadbear makes a Convex deployment in
your own account") gets reworded to match whatever 1 decides.

## Research notes

How things work today, from a read of the repo on 28 Oct:

- Install: `app/install.sh` (checks swift and python3, runs `setup_mac.sh`, which runs
  `build-app.sh`); `runner/scripts/install-runner.sh` (main's tip only, not from inside a
  thread, Node 24 at the nvm path, writes the LaunchAgent, first release through
  `deploy.mjs`).
- Runner updates: `runner/src/update.ts` (every 5 minutes and on ref changes, clones from
  the local checkout's `refs/heads/main`, builds when the runner's tree changed, idle
  restart); `runner/launch.mjs` (rollback to `lastGood` after 3 bad boots in 10 minutes).
- App updates: `app/Sources/Threadbear/AppUpdate.swift` and `app/stage-update.sh` (same
  local-main model, swaps the bundle on quit or launch).
- Convex: `convex/lib.ts` (`RUNNER_KEY`), `runner/src/sync.ts` (`sync.url` and
  `secrets/convex-key`), `convex/push.ts` (`APNS_*` env), docs/convex-backend.md.
- Phone: `ios/ThreadbearKit/Sources/ThreadbearKit/Pairing.swift` (only `*.convex.cloud`
  and `*.convex.site`), `ios/scripts/pair-qr.swift`, `ios/scripts/install-phone.sh`
  (Mike's phone and App Store Connect key).
- Network: `runner/src/config.ts` binds `127.0.0.1`; docs/convex-backend.md section 2
  ruled out the phone talking to the runner directly because the Mac sleeps.
