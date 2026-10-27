# Comparing design options

Design pass, 27 October 2026. Implementation waits for Mike's choice.

Open `index.html` to compare the directions, then open either mockup at full
browser size. `./render.sh` renders all three views with the existing headless
Chromium, following `docs/threadbear-design/render.sh`. No install is needed.
The source images are referenced from `docs/account-picker-design/`; nothing
in that folder is modified.

- **A: a comparison window** (`1-window.html`), recommended. Resizable,
  modeless, owned by a review rather than the currently selected thread.
  Plenty of room, and can go full screen. Start in a grid for larger sets,
  then compare any two. This screenshot shows the pair view with an example
  draft choice and note.
- **B: a right-hand panel** (`2-panel.html`). Keeps the transcript visible,
  but two large mockups become quite small. Even at 1440 points wide the
  comparison competes with the transcript. If chosen, it needs an option
  to open in a window.
- **A at readable size** (`3-readable-size.html`). The same comparison
  window with both images at their original logical size (the PNGs are
  2x), scrolled to the picker. Fit is for an overview; 100% and scrolling
  are for reading. The original files have different aspect ratios and
  should never be cropped silently to a common thumbnail shape.

The mockups support changing the pair, a grid, single-image mode, keyboard
browsing, Fit / 100%, an optional pick, per-image notes and a reply preview.
They are static prototypes with local page state, no persistence and no
connection to the runner. The sample choice and note are illustrative.
`Review later` only changes the status text in the mockup.

## Recommendation

Use a first-class review object and a compact card in the transcript, which
opens A. A native modeless window gives a comparison enough room, keeps the
thread usable, and can preserve its own position when Mike switches threads.
A sheet limits the review to the parent window and blocks that thread. The
existing right panel is a useful eventual alternate location for the same
review UI, especially for HTML, but not the default for comparing images.

The fourth account-picker image describes behaviour common to the other
options, so it is marked Reference and can get notes without a Pick button.
This distinguishes context from a mutually exclusive design choice.

## Implementation outline, after approval

Change `docs/protocol.md` first. Add a review request/response contract usable
by both Claude and Codex through the existing Threadbare MCP server. Proposed
tool: `show_options({ title, note?, options: [{ id, title, path, note?,
reference? }] })`. Names and final schema remain to be decided with the
protocol change. Import files when the review is created, not when the app
first opens it; keep their bytes with the thread so later file edits, moves
or a worktree being removed do not change the review.

Make the review durable, with a stable ID, option IDs and pending/answered
state. Return the ID promptly from the MCP tool, so the agent can finish its
turn rather than hold a CLI open. The pending card stays in Needs you across
turn-end, app close and runner restart; answering it sends the review's
structured result plus readable text into the originating thread. A running
agent gets that reply through the existing send path; an idle one resumes.
The result names the review and stable option IDs, so it remains unambiguous
with multiple reviews outstanding. Cancellation and stale/duplicate replies
need explicit outcomes. Answering twice must not start two turns.

Client: decode unknown fields/event kinds tolerantly; keep pending review
cards outside work groups; persist draft notes and choice; opening/closing a
window never submits; submit all notes and the optional pick atomically.
Allow notes-only replies. Show answered state on the original card and keep
its assets available for later inspection. One review window per review ID;
reopening focuses the existing one. Do not steal focus on arrival.

V1: image files, grid / pair / single, Fit / 100% and scrolling, arrow keys,
per-option notes, pick/unpick, saved draft and one submitted reply. HTML
previews and synchronized pan / overlay are later additions. Existing URL
panels host web views but have no review-answer bridge, so a patch alone
does not satisfy the response flow. This pass does not add a patch or an
account-picker feature.

Before code, write meaningful runner and core regression tests for persistence,
imported assets, review responses, duplicate submission and card reduction.
Verify the approved UI against the four real account-picker images in a debug
app behind Mike's window; use `app/Tools/screenshots.sh` for app screenshots.
No app code changes are part of this design pass, so these HTML renders use
Chromium directly.
