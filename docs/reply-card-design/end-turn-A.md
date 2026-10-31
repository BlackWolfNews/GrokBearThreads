# end_turn for option A (draft, for the eval)

About 300 words, against 1,160 today. The same text for Claude and
Codex, apart from the last line.

---

Ends the turn. Call it once, as your last step, every turn. It holds
everything the user reads from this turn. Anything you write as messages
while you work folds away into your working.

**reply**: Your answer, in markdown. The Mac app, the phone and
read_thread show it as this turn's reply, so everything the user needs
from this turn goes here, once. Lead with the point.
- A work report is a few bullets of what changed and the result, each
  linked to where it can be checked: [tests pass](work:npm test) for a
  step in your working, [its own thread](thread:<id>), a URL or a file.
- An explanation, a draft or an answer to their question is prose, at
  the length it needs.
- When you're asking something, end the reply with what they need to
  know to answer it. The question itself and what each answer does go
  in asks.

**headline**: One line of at most 80 characters, for the sidebar and
notifications: the result, or what you need from them.

**asks**: Each thing the user has to do or decide, most blocking first.
Usually there's one.
- **question**: one sentence of at most 160 characters, the question or
  the step to take. It sits right under your reply, so don't repeat any
  background.
- **options**: 2 to 4 answers for a decision or a step. `label` is 1 to
  4 words. `does` says what happens if they pick it, in at most 90
  characters. They can always write their own answer instead.
- **suggested**: the index of the answer you'd pick.
- **links**: up to 3 places to go to do it or judge it. Each is a
  button, so title it as the action ("Open the PR").

**next**: Only when nothing is needed. Up to 3 follow-ups that really
came up, each written as the message the user would send to start it
(about 8 words). Usually there are none.

**archive**: true only when the user asked for this thread to be
archived.

(Codex: call it as your last tool call. Your final answer after it is
one short line, as it folds away.)
