# Threadbear

Mike's agent app for Mac: a native app and a small runner that drive the
official Claude Code and Codex command line tools, with your threads mirrored
to a Convex deployment of your own so an iPhone app and a website can follow
along. More at [threadbear.mikecann.app](https://threadbear.mikecann.app).

## Setting it up

You need a Mac with Apple silicon, Xcode 26 or newer, Node 24 or newer, Claude Code or Codex (logged in), and a free
[Convex](https://convex.dev) account. Tailscale is optional.

```sh
gh repo fork mikecann/threadbear --clone
cd threadbear
./threadbear setup
```

A fork rather than a plain clone, so your own changes have somewhere to live
and Mike's updates can still come in. Setup checks the Mac, makes sure Mike's
repo is your `upstream` (forking it for you if you cloned it), logs you in to Convex, makes a Convex project with a
production deployment in your account, makes the keys the runner needs,
deploys the backend and the website, and builds and installs the runner and
the Mac app. Then, in the app, Settings › Phone & browser pairs the iPhone
app (a code to scan) and opens the website in your browser, signed in. Run
setup again whenever you like: it only does what's missing.
`./threadbear setup --dry-run` shows what it would do.

Or have your agent do it: ask Claude Code or Codex to "fork
https://github.com/mikecann/threadbear and clone the fork to ~/threadbear,
then read INSTALL.md there and follow it". INSTALL.md walks an agent through it and says when to
stop and ask you.

After that, the runner and the app update themselves whenever your `main`
changes, deploying your Convex backend first (docs/setup-and-updates.md).
Mike's own changes come as a signed release about once a day; the app's
Updates panel says when there's one, and Bring Them In starts a thread that
merges it with your changes and asks before it lands
(docs/bringing-in-updates.md).

## Where things are

- `runner/`: the runner (TypeScript), `app/`: the Mac app (SwiftUI and AppKit),
  `ios/`: the iPhone app, `convex/`: the backend, `web/`: the website,
  `relay/`: the push relay (Mike's, shared), `site/`: the landing page.
- `docs/guide.md` for using it, `AGENTS.md` for agents working on it, `docs/`
  for how it all works.
