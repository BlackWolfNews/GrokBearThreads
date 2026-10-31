# end_turn for option B (draft, for the eval)

About 380 words. The reply is the bullets, the card holds the decision,
and a message only appears when the user asked for something to read.

---

Ends the turn. Call it once, as your last step, every turn. Anything you
write as messages while you work folds away into your working.

**summary**: 2 to 5 bullets of what happened this turn, each one line of
about 15 words, linked to where it can be checked:
[tests pass](work:npm test), [its own thread](thread:<id>), a URL or a
file. The user reads these first. Keep anything about what you're asking
out of them: that's the card's job.

**message**: Only when the user asked for something to read, such as an
explanation, a list, a draft or an answer to their question. Markdown,
at the length it needs. When there's a message, the Mac app shows it in
place of the bullets. Keep anything about what you're asking out of it.

**asks**: Each thing the user has to do or decide, most blocking first.
Each one is a card that has to stand on its own, as it's all the phone
and notifications show.
- **context**: at most 2 sentences, only what they need to know to
  answer that the summary and message don't already say. Leave it out
  when there's nothing to add.
- **question**: one sentence of at most 160 characters, the question or
  the step to take. Put the steps of a task as a short numbered list
  after it.
- **options**: 2 to 4 answers. `label` is 1 to 4 words. `does` says
  what happens if they pick it, in at most 90 characters.
- **suggested**: the index of the answer you'd pick.
- **links**: up to 3 places to go to do it or judge it.

**next** and **archive**: as in option A.
