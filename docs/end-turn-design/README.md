# End of turn: a summary, then what's next (29 Oct 2026)

Mike, after Codex desktop: when a thread hands back, he wants the least
context to load and a clear next step. A few bullets of what it did, then
what it needs from him, with links back into the detail: another thread, a
web page, a button that does something, or the thread's own working,
opened at the step a bullet is about and lit up. Render with `./render.sh`.

1. `1-summary-in-reply` The agent's final message is the summary: short
   bullets with inline links. `↑` links point into the working above, `↗`
   at the web, `◦` at another thread. The Needs you card under it is
   today's, unchanged.
2. `2-one-card` The summary moves into end_turn (`done`) and the card
   holds both: the bullets, with the same inline links, then Needs you.
   No message above it; everything else the agent wrote that turn folds
   into "Worked for 14m".
3. `3-show-working` What clicking a `↑` link does: the fold opens,
   scrolls to the step, and lights it (accent rail, tint); the steps
   around it dim. Clicking elsewhere folds it again.
4. `4-nothing-needed` A done turn in the style of 2.

## How a bullet points at a step

The model can't see the ids of its own tool calls, so a work link quotes
the step instead: `[tests pass](work:npm test)`, a few words copied from the
command it ran or its description, the file it edited, or a line it wrote
while working. The app looks through that turn's working: a command that
starts with the words beats a step that mentions them, which beats one
whose output does, and the latest wins a tie. `thread:<id8>` opens another
thread. Both work in markdown and as ask buttons.

The eval that tested the wording on real models is in
`~/dev/me/misc/end-turn-eval` (results below).

## What the eval found (36 real sessions, $4.68)

Three throwaway tasks (a bug fix with a related older thread, a question
with nothing to change, a fix that ends on a missing API key), a stand-in
`threadbear` server with the draft end_turn, reply-first refused as the
runner does. Opus 5.5 twice and Haiku 5.5 once per task per option in the
last round, after two rounds that fixed the wording and the rig.

- **1, summary in the reply, doesn't work on Opus.** 6 of 6 Opus runs wrote
  a prose paragraph, no bullets, no links. Opus often sends its last reply
  as a narration block, which it doesn't format the way it's told. Haiku
  did bullets, but 30 to 50 words each.
- **2, summary in end_turn, does.** 9 of 9 runs put the summary in `done`:
  4 or 5 bullets of 15 to 22 words. Every work link and thread link landed
  on the right step or thread, once the matcher also reads a tool call's
  description ("Fix import typo and rerun"), which Opus likes to quote.
- Four things to build in alongside 2:
  - `needs` was left out 2 times in 9: infer it from whether there are asks.
  - Once, Opus called end_turn again after it was accepted: refuse a second.
  - 4 runs in 9 added a line after end_turn ("It's all in the card above"):
    fold anything written after it into the working, out of sight.
  - Links came on about half the bullets. Fine, as a bullet without one
    still reads; the prompt can ask for more.

## What Mike picked, and what shipped

Mike picked 1, the look: the bullets read as the agent's own message,
with today's Needs you card under them. Given the eval, they come from
end_turn's `summary` rather than the message: the runner writes them into
the thread as the turn's reply (`assistant.text` with `summary: true`),
and the app folds the turn's other messages into its working, so on
screen it is 1. The four guards went in with it. The `↑` after a work link
shipped; `↗` and `◦` didn't, as web links already peek on hover and
thread links open on click. The lit-up step fades after a few seconds
rather than waiting for a click elsewhere, and the group stays open.
A real Opus turn and a real Codex turn through a dev runner both wrote
their summaries in end_turn unprompted by anything but its description.
