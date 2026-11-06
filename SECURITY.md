# Security

## Reporting a problem

Please use GitHub's private vulnerability reporting: the **Report a vulnerability** button on this repo's [Security tab](https://github.com/mikecann/threadbear/security). Don't open a public issue, and keep tokens, keys and private thread content out of anything you send.

Threadbear is one person's project, so there's no formal timeline. I'll aim to reply within a few days and to fix anything real on `main` as soon as I can. Only the latest `main` is supported.

## What Threadbear is, security-wise

Threadbear runs Claude Code and Codex agents on your own Mac, with your own logins. Everything is built for **one owner per deployment**: you, your Macs, your phone and your browser, and a Convex backend you deploy yourself. There are no other users or tenants inside a deployment.

The agents themselves have whatever access you give them. New threads start with full access by default, the same as running the CLIs with permissions skipped. Threadbear doesn't sandbox an agent. Its job is to not hand anything *more* to code or text you haven't chosen to trust.

## What it protects

- **Your Mac from a repo you open.** A project's patches (`.threadbear/patches`), the scripts they run and its own Claude Code hooks, commands and environment settings don't run until you trust them. Trust covers the exact bytes, so a later change asks again, and anything it can't check fails closed ([protocol: Trusting a folder's patches](docs/protocol.md)).
- **Ask and Auto threads from raising their own access.** An agent in a thread set to Ask or Auto can't switch its own or any other thread or schedule to more access, start a thread with more access than its own, send a message to a thread that has more (or move it, or put words in a project brief it reads), or add a schedule check (a shell command), unless you allow that one call on a card. That card has no "Always allow", and no rule or Auto's classifier answers it. A thread with full access can already run anything as you, so it isn't asked.
- **"Always allow" on a Codex command** covers that exact command in that folder, never a prefix of it, and is never offered for a shell, interpreter or other program that runs code it's handed.
- **Ask and Auto from becoming code that runs.** In those modes an agent's edit to a patch, a file a patch uses or Claude Code's settings always asks, with no Always allow, and what it writes waits for you to trust in Patches. Only a Full access thread's own edits are trusted as it leaves them, and an edit to a file you hadn't trusted doesn't trust the rest of it.
- **One Mac from another.** Each extra Mac has its own key, which can only act as that Mac. It can't read or change another Mac's threads, commands or secrets, or pair phones. Its usage readings reach no other Mac, so it can't stop one using a login, and which logins it gets the main Mac's readings of is the main Mac's word (`tb runner logins`), never what it says it's signed in to. The main Mac's key can do everything ([protocol: Runner keys](docs/protocol.md)).
- **Secrets you type on your phone.** They're sealed to the Mac named in your pairing code, so the backend and other Macs can't read them.
- **Your phone and browser logins.** Tokens are stored only as hashes, expire, and can be revoked, which also stops that phone's notifications.
- **Shared threads.** A share link is a public, read-only bearer link. It shows only that thread, and only pictures from the thread's own media folder.
- **Your copy from a hijacked upstream.** On a fork, only `release/*` tags with an SSH signature by the release key setup pinned count as Mike's releases; a PGP or X.509 signature never does. A release keeps the tag it verified with, and bringing it in merges the commit that was checked ([protocol: Mike's releases](docs/protocol.md)).
- **Approvals you chose, through a review.** A review by another lab (an experiment) runs with the reviewed thread's own permissions, never more, and is told the change and replies it's handed are data, not instructions.
- **Another Mac's address.** The Mac app only sends a runner's token to the host you pinned for it, never one the backend suggests.

## What it assumes

- Your Mac account is yours. Other processes running as you are trusted.
- Commits on the `main` your runner follows are yours. The runner builds, deploys and restarts from it.
- Your Convex deploy keys, CLI login and the main runner key stay on your main Mac.
- Remote runners are reached over Tailscale or a similar private network.
- Anyone with a share link can read that thread while sharing is on.

## Shared services

- **The push relay** is run by me so the App Store app can get notifications. It sees device tokens and encrypted notification text, and only registers Convex deployments that prove who they are. Forks can run their own (`relay/`).
- **Sentry** gets crash reports from release builds only, with no thread text.

## Out of scope

- What an agent with full access chooses to do on your Mac, including after a prompt injection. That's the agent's permission mode, which you choose.
- Problems that need your Mac account, your Convex admin access or your `main` branch already in someone else's hands.
- The marketing site in `site/`, beyond the usual.
