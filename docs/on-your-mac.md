# What Threadbear does on your Mac

Everything Threadbear installs, runs in the background, reads, and talks to
over the network. It's here so you, or the agent installing it for you, can
check the code against it before running anything. If the code does
something that isn't on this list, treat that as a problem and say so.
File references are where to look.

## What setup and install add

- **Git remotes** (`scripts/setup.mjs`, "Your copy"): Mike's repo becomes
  `upstream`. If `gh` is logged in and you cloned rather than forked, setup
  forks the repo to your GitHub account (`gh repo fork --remote`).
- **Packages:** `npm ci` in the repo, in `runner/`, and in each runner
  release. esbuild and fsevents have install scripts.
- **Convex, in your own account:** a login (`~/.convex/config.json`), a
  project with a production deployment, a deploy key, and one environment
  variable (`RUNNER_KEY`). It deploys `convex/` and the `web/` site there.
- **Apps:** `~/Applications/Threadbear.app` and
  `~/Applications/Threadbear Runner.app`, both built and signed on your Mac.
- **A LaunchAgent:** `~/Library/LaunchAgents/com.mikerosoft.threadbear.runner.plist`,
  which keeps the runner going while you're logged in.
- **A command:** `~/.local/bin/threadbear`.
- **Files:** the data folder `~/Library/Application Support/Threadbear`
  (threads, settings, `secrets/`, runner releases, and the pinned release
  key `upstream-signers`); `~/Library/Caches/Threadbear/update`;
  `~/Library/Caches/Threadbear/remote` (copies of pictures and files from
  threads on your other Macs, at most 512 MB, unused ones go after 30 days);
  `~/Library/Logs/threadbear-runner.log` and `threadbear-update.log`;
  `~/Library/Logs/Threadbear/hangs` (the last 10 times the app froze: if its
  main thread is stuck for 4 seconds it runs macOS's `sample` on itself, and
  nothing else ever reads these); and `~/ThreadbearThreads`, the default
  folder for new threads. The runner also runs `ps`, and `sample` on a
  thread's own CLI, when a turn has been quiet for a minute,
  to tell a CLI frozen on a macOS prompt from a long job. The sample is a
  temp file, deleted straight after.

## What runs in the background

- **The runner** listens on `127.0.0.1:8797` only, and needs a token
  (`runner/src/config.ts`). It starts the official `claude` and `codex`
  CLIs for your threads.
- **Agents get full access by default.** Claude runs with
  `bypassPermissions` and Codex with `danger-full-access`. "Ask before
  edits" is a choice for each thread.
- **Following your main** (`runner/src/update.ts`, `app/Sources/Threadbear/AppUpdate.swift`):
  every 5 minutes the runner and the app check your local `main`. When
  it has changed, they rebuild themselves from it and redeploy your
  backend. Turn it off with `followMain: false` in `runner.json`.
- **Mike's releases** (`runner/src/upstream.ts`): every 6 hours it fetches
  `upstream`'s signed `release/*` tags. It only tells you about them; it
  never changes your code.
- **CLI updates** (`runner/src/updates/`): every hour it checks for new
  Claude Code and Codex versions and installs them. If you don't point it
  at your own Codex, it installs one into the data folder.
  `THREADBEAR_CLI_UPDATES=off` stops this.
- **Small model calls** (`runner/src/models/`): thread titles, filing
  threads into projects (the librarian, every 5 minutes) and similar jobs
  send short excerpts of your threads to `claude -p` on your own logins.
  When a project's notes pass 12,000 characters, the librarian sends them
  the same way to be rewritten shorter, and keeps the old notes in the
  data folder's `project-notes/` (the last 5 for each project).
- **Housekeeping** (`runner/src/housekeeping.ts`): trims logs and deletes
  old pasted images, trash and archived threads' media.
- **Presence** (`runner/src/presence.ts`): reads how long the keyboard and
  mouse have been idle (`ioreg`), so your phone knows whether you're at
  the Mac.
- **Patches** (`.threadbear/patches/`): code from a folder runs only after
  you trust that folder (`runner/src/patch-trust.ts`).

## What it reads

- From your Claude and Codex logins: which account each is (the email in
  `~/.claude.json`), a few settings, and the token counts in your session
  transcripts, so it can show how much room each login has
  (`runner/src/accounts.ts`, `runner/src/token-tally.ts`;
  `THREADBEAR_TOKEN_TALLY=off` stops the counting). It never reads or
  copies login tokens or the Keychain.
- Token Stats' files, if you have that app.
- Your first name, from your Mac account's full name (`id -F`), so its
  agents know what to call you (`runner/src/user-name.ts`). It stays in
  the instructions your own threads get.

## Who it talks to

| Service | Whose | What goes there |
|---|---|---|
| Your Convex deployment | yours | Thread titles and status, all message text (each message cut at 8,000 characters), one line per tool call, projects, schedules, your logins' emails and usage, whether you're at the Mac. Photos you send from the phone, deleted once the Mac has fetched them. Other images only for threads you share by link. Tool output and files stay on the Mac. |
| GitHub | Mike's repo | Release tags fetched every 6 hours; the fork at setup |
| downloads.claude.ai, registry.npmjs.org | Anthropic, npm | CLI version checks and installs; `npm ci` |
| Anthropic, OpenAI | yours | Your threads, through the official CLIs on your own logins |
| Mike's push relay | Mike's | Only when a paired iPhone gets a notification. It's sent from your Convex deployment, not the Mac. The text is encrypted for the phone; the relay sees the device token and thread id (`convex/push.ts`, `docs/push-relay.md`). |
| OpenRouter | theirs | Thread excerpts, only if you add a key |
| A Connectors gateway | whoever runs it | Only if one is set in `runner.json` or `~/.claude.json`. Its `/health` every few minutes, and for a project with a Notion page, a Notion read or two every 5 minutes for its task board (`runner/src/notion-tasks.ts`) |
| Sentry | Mike's | Nothing from your copy. Only a copy whose `origin` is Mike's own repo reports errors (`runner/src/sentry.ts`, `app/Sources/Threadbear/CrashReporting.swift`). The App Store iPhone app sends anonymous crash reports. |

On the Mac itself, a web link you click in the app first goes to
BrowserBear's socket (`~/Library/Application Support/BrowserBear/browserbear.sock`),
if you have BrowserBear, to ask whether an agent's Chrome tab is already
on that page (`app/Sources/Threadbear/BrowserBear.swift`). Only the link
goes there.

Nothing else: no analytics, no ads, no tracking.
