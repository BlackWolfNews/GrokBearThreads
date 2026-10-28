# Threadbear

Mike's agent app for Mac: a native app and a small runner that drive the
official Claude Code and Codex command line tools, with your threads mirrored
to a Convex deployment of your own so an iPhone app and a website can follow
along. More at [threadbear.mikecann.app](https://threadbear.mikecann.app).

## Setting it up

You need a Mac with Apple silicon, Xcode 26 or newer, Node 24 or newer, Claude Code or Codex (logged in), and a free
[Convex](https://convex.dev) account. Tailscale is optional.

```sh
git clone <your fork> threadbear
cd threadbear
./threadbear setup
```

Setup checks the Mac, logs you in to Convex, makes a Convex project with a
production deployment in your account, makes the keys the runner needs,
deploys the backend and the website, and builds and installs the runner and
the Mac app. Then, in the app, Settings › Phone & browser pairs the iPhone
app (a code to scan) and opens the website in your browser, signed in. Run
setup again whenever you like: it only does what's missing.
`./threadbear setup --dry-run` shows what it would do.

Or have your agent do it: ask Claude Code or Codex to "clone
https://github.com/<you>/threadbear to ~/threadbear, then read INSTALL.md
there and follow it". INSTALL.md walks an agent through it and says when to
stop and ask you.

After that, the runner and the app update themselves whenever your `main`
changes, deploying your Convex backend first (docs/setup-and-updates.md).

## Where things are

- `runner/`: the runner (TypeScript), `app/`: the Mac app (SwiftUI and AppKit),
  `ios/`: the iPhone app, `convex/`: the backend, `web/`: the website,
  `relay/`: the push relay (Mike's, shared), `site/`: the landing page.
- `docs/guide.md` for using it, `AGENTS.md` for agents working on it, `docs/`
  for how it all works.
