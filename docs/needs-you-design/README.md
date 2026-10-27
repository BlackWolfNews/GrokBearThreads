# Needs-you concepts (27 Oct 2026)

Instead of a classifier, the agent says whether it needs Mike, with an
`end_turn` tool from the runner's `threadbare` MCP server. The asks from
"What I need from you" become a tick list. Folds in the checklist idea from
thread 52879648. Render with `./render.sh`.

1. `1-needs-you` The ask card, and the sidebar row showing the first open ask.
2. `2-tick-and-reply` Ticking never sends; a reply chip fills the composer.
3. `3-done` A done turn: a quiet line, Inbox not Needs you, the old card frozen.
4. `4-how-its-decided` The tool, the order that decides the row, notifications.

What shipped differs in two ways: sidebar rows lost their second line on
main before this landed, so the first open ask shows in the transcript card
and in notifications rather than the row, and "Done, nothing needed" sits
in the turn's footer rather than on its own line.
