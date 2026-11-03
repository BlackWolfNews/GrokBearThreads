# Marking the wait between two replies in one turn (3 Nov 2026)

A thread whose agent waits on sub-agents writes "still running" and then,
minutes later in a turn of its own, "it's back". With the work folded
into one line above, the two sat one under the other as if said in one
breath. Four ways to show the wait, from Mike's Let's Build It thread:

- 0-today: how it looked.
- 1-divider: a thin line with the wait and what finished. **Mike picked this.**
- 2-wait-row: a row like a tool step, "Waited 6 min · ✓ Mine LBI repo".
- 3-fold-stale: out-of-date "still waiting" messages fold into one grey line.
- 4-gutter: each reply's time in the left margin.

Built as `TurnGap` (app) from `turn.started`'s `wokeBy` (runner).
`render.sh` renders the HTML to PNG.
