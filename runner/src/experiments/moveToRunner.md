---
id: moveToRunner
name: Move to another machine
title: Move to another machine: a thread moves to another runner whole, and carries on there
added: 2026-11-08
on: false
reminder: pending
---

## What it does

A thread's menu has **Move to**, with each of your other machines. Pick one, check the folder and login it will use there, and the thread moves: the same thread, with its whole conversation, its pictures and Highlights, and the git work in its own worktree (commits and uncommitted changes alike). It waits for the turn it's on to end, and messages you send meanwhile go with it. Its next message carries on in the same Claude session on the other machine. If anything goes wrong before it lands, it stays where it was and says why. An agent can do it too, with `move_thread` and a `runner`.

It needs Threadbear's backend, and the experiment on in both machines' runners.

## Lives in

`runner/src/moves.ts` (the steps on each runner), `move-pack.ts` and `move-git.ts` (the bundle and the git work), `sealBytes` in `secrets.ts`; `convex/moves.ts` and the `threadMoves` table in the backend; the Move to menu in the Mac app.

## Taking it out

Delete `runner/src/moves.ts`, `move-pack.ts` and `move-git.ts` and their lines in `main.ts` and `sync.ts`, and the Move to menu in the app. The backend's `convex/moves.ts` can stay: nothing starts a move without the runner.
