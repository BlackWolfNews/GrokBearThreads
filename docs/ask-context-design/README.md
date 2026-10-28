# Where the reason for an ask lives (28 Oct 2026)

Mike, looking at a Needs you card as a user: the message above it had no
context for what was wanted or why. The reason was only in small grey
text under a big bold question, which is backwards: you explain, then ask.
Three ways to fix it, all showing the power-aware lock turn (thread
69ad3732), rendered with `./render.sh`:

1. `1-question-card` The message explains at normal size and runs straight
   into a card with just the questions and their buttons. The changed files
   move above the message, so nothing sits between the reason and the ask.
2. `2-message-asks` Same message, no box: the questions are the end of the
   message, marked by an accent rail.
3. `3-context-in-card` The card keeps the reason but puts it first, at body
   size, then the question. The message stays short. Closest to today.
4. `4-same-text` Mike's idea after seeing those: the card is the agent's own
   "What I need from you" list, word for word and drawn like message text,
   with each ask's buttons under its paragraph. The agent writes each ask
   once (end_turn's action and why, read as one paragraph) and the message
   doesn't repeat it.

Mike picked D ("that looks about right"). What shipped: the card draws each
ask as `Decisions.paragraph` (action, a full stop if it has none, then why)
through the markdown renderer, a list item when there are several, with
its buttons in line with the text (RowRenderer.asksText). end_turn's
description tells agents the asks are their "What I need from you" list
and not to repeat it in the message, and `where` left its schema (the
paragraph says it). The global CLAUDE.md says the same for Threadbear.
The card stays under the turn's footer, where Mike put it on 28 Oct; the
mockups' changed files above the message didn't ship.
