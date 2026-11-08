---
id: moveToRunner
name: Move to another machine
title: Move to another machine: a thread moves to another runner whole, and carries on there
added: 2026-11-08
on: false
reminder: be94a128
---

## What it does

A thread moves to another of your machines whole: the same thread, with its whole conversation, its pictures and Highlights, and the git work in its own worktree (commits and uncommitted changes alike). It waits for the turn it's on to end, and messages sent meanwhile go with it. Its next message carries on in the same Claude session on the other machine. If anything goes wrong before it lands, it stays where it was and says why.

So far it's started from the main Mac's runner (`threads.move`); the Mac app's **Move to** menu and `move_thread` with a `runner` come next. It needs Threadbear's backend, and the experiment on in both machines' runners.

## Lives in

`runner/src/moves.ts` (the steps on each runner), `move-pack.ts` and `move-git.ts` (the bundle and the git work), `sealBytes` in `secrets.ts`; `convex/moves.ts` and the `threadMoves` table in the backend; the Move to menu in the Mac app.

## Taking it out

Delete `runner/src/moves.ts`, `move-pack.ts` and `move-git.ts` and their lines in `main.ts` and `sync.ts`, and the Move to menu in the app. The backend's `convex/moves.ts` can stay: nothing starts a move without the runner.
