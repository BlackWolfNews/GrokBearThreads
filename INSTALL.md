# Installing Threadbear (for an agent)

You're an agent (Claude Code, Codex or similar) installing Threadbear on the
Mac you're running on, for the person you're working with. Follow these steps
in order. Stop and ask them at the points marked **Ask**; everything else you
can do yourself. `README.md` says what Threadbear is.

## 1. Check the Mac

Run these and fix what's missing before going on:

- `sw_vers -productVersion` and `uname -m`: macOS on `arm64` (Apple silicon).
- `xcodebuild -version`: Xcode 26 or newer. If it's missing or older, **Ask**
  them to install Xcode from the App Store and open it once, then carry on.
- `node -v`: 24 or newer. If not, install it with nvm
  (`nvm install 24 && nvm use 24`) or Homebrew (`brew install node@24`), and
  use that `node` for the rest.
- Claude Code (`~/.local/bin/claude` or `claude` on the PATH) or Codex
  (`codex`): one of them installed and logged in. You're probably running in
  one of them already.
- `launchctl print gui/$(id -u) >/dev/null && echo yes`: says `yes` when
  someone is logged in to the desktop. The runner only starts for a desktop
  login, so if it says nothing, **Ask** them to log in to the Mac's desktop.

## 2. Get the code

If you aren't in a copy of the repo already, fork it rather than cloning
it, so their changes have a home of their own and Mike's updates can still
come in:

```sh
cd ~ && gh repo fork mikecann/threadbear --clone
```

If `gh` isn't logged in (`gh auth status` fails, which an expired login
does too), run `gh auth login --web` and **Ask** them to approve it in the
browser. If they'd rather not use GitHub, a plain
`git clone https://github.com/mikecann/threadbear ~/threadbear` works too:
setup then makes Mike's repo their `upstream`, and they can fork later.
Work from `~/threadbear` from here on.

## 3. Run setup

Look first, without changing anything:

```sh
./threadbear setup --dry-run --yes
```

**Ask** them, in one message:

- whether this Mac is joining a Threadbear they already have on another Mac
  (then: the name of that Convex project),
- otherwise, what to call their new Convex project (default `threadbear`),
- and if the dry run said their Convex login has several teams, which team
  it goes in (pass it as `--team <slug>`).

Then run it, with their answers:

```sh
./threadbear setup --yes --project <name>
# joining an existing project instead:
./threadbear setup --yes --existing --project <name>
```

New threads start in `~/ThreadbearThreads`, which setup makes (not
`~/Threadbear`: macOS ignores case, so that would be this repo's folder).
They can change it in the app's Settings, and pick a folder for each
thread as they start it.

It takes a few minutes (it builds the Mac app). Along the way:

- If they aren't logged in to Convex, it opens a Convex page in the browser
  and waits. **Ask** them to approve it (and to make a free account if they
  haven't got one).
- If their Convex login has several teams, it stops and lists them. **Ask**
  which one, and run it again with `--team <slug>`.
- Any other stop says what's wrong; fix it and run the same command again. It
  carries on from where it got to.

It finishes with "Threadbear is set up." Then open the app:
`open ~/Applications/Threadbear.app`.

Setup also puts `Threadbear Runner.app` in `~/Applications`. It's the small
program that runs the runner in the background; it isn't for opening. When
an agent in a thread first reads a protected folder (Desktop, Documents,
Downloads, iCloud or Dropbox), macOS asks whether to let "Threadbear Runner"
do that. Tell them that prompt is Threadbear's, so they can answer it.

## 4. The phone and the browser

Both happen in the app, in Settings (⌘,) › Phone & browser. **Ask** them to
open it there:

- "Show the code" shows a QR code to scan with the Threadbear iPhone app.
- "Open signed in" opens their Threadbear website in their browser, signed in.
- The same tab lists what's paired, each with Revoke.

The terminal scripts still work when there's no app window to hand
(`npm run web:sign-in`, and `swift ios/scripts/pair-qr.swift --prod --url
<the URL setup printed>`), but never show or print a pairing link or token
yourself: it can run their agents.

## 5. Tell them it's done

Say what was set up (their Convex project and its URL, where the app is), and
that the runner and app update themselves when their `main` changes.
