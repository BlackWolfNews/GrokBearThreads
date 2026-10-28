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

If you aren't in a clone of the repo already, clone the person's fork (or
`https://github.com/mikecann/threadbear` if they haven't forked it) to
`~/threadbear` and work from there. If git needs a GitHub login, run
`gh auth login --web` and **Ask** them to approve it in the browser.

## 3. Run setup

Look first, without changing anything:

```sh
./threadbear setup --dry-run --yes
```

**Ask** them, in one message:

- what to call their Convex project (default `threadbear`),
- which folder new threads should start in (default their home folder),
- if this Mac is joining a Threadbear they already have on another Mac: the
  name of that Convex project.

Then run it, with their answers:

```sh
./threadbear setup --yes --project <name> --cwd <folder>
# joining an existing project instead:
./threadbear setup --yes --existing --project <name> --cwd <folder>
```

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

## 4. The phone and the browser

Tell them the two commands setup printed at the end, and offer to run them:

- `npm run web:sign-in` opens their Threadbear website in Chrome, signed in.
- `swift ios/scripts/pair-qr.swift --prod --url <the URL setup printed>` shows
  a QR code to scan with the Threadbear iPhone app. **Ask** them to scan it.
  Never show or print the pairing link or token yourself: it can run their
  agents.

## 5. Tell them it's done

Say what was set up (their Convex project and its URL, where the app is), and
that the runner and app update themselves when their `main` changes.
