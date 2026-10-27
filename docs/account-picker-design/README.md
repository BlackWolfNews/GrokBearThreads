# Account picker concepts (27 Oct 2026)

Mike asked for an "auto" account choice, like Theo's CLI proxy, and maybe one
picker for account and model like T3's. Three takes, plus what a mid-thread
move looks like in all of them. Render with `./render.sh`.

1. `1-auto-account` A. Auto as the first row of today's account menu.
2. `2-one-picker` B. Account chip gone; an Account line (Auto by default) under Effort in the model picker.
3. `3-pools` C. Pools (Claude, Convex, Codex) down the side instead of logins.
4. `4-moving-mid-thread` How an Auto thread moves login when one runs dry.

Today, before any of this: new threads already start on the Claude login with
the most room (`pickAccount` in runner/src/usage.ts and AccountUsageText.swift),
skipping noted, blocked and under-10% ones. Model and effort follow the last
change made in any thread, per provider. What's missing is that it isn't
shown as Auto, and nothing moves a thread once it's running.
