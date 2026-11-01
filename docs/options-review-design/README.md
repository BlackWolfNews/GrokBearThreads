# Comparing design options

**1 November 2026: the window was redone.** `4-all-plus-form.png` is the layout
Mike picked (`~/dev/me/misc/threadbear-options-window` has the other two he
compared). Every image stays on a stage, sized by how many columns make them
biggest, with the question, the choices and their reasons, a note on any of
them and Send on the right. Picking opens that choice's note box and puts the
cursor in it. Click an image to enlarge it, and again or Esc to see them all.
Grid, 2-up, the thumbnail strip and Later went; closing the window keeps the
draft. The dock's Review panel described below went too, as reviews have only
opened in their own window since 30 October. The usage notes below describe the earlier window where they differ.
The reply format didn't change.

Design pass, 27 October 2026. Mike approved A, the separate comparison window.
On 28 October he asked for it as a panel instead: a review now opens in the
dock's Review panel beside its thread, with a button in its bar to pop it out
into the window, and less text (icon view and zoom controls, no filmstrip in
the grid, a click on an image to open it with its notes).
The HTML files below remain the original design prototypes. V1 is built in
the native app and runner; usage is at the end of this document.

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
by both Claude and Codex through the existing Threadbear MCP server. Proposed
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

## Using V1

An agent calls `threadbear.show_options` with image paths and stable option
IDs. For example, from this repo:

```json
{
  "title": "Account picker",
  "options": [
    { "id": "A", "title": "Auto account", "path": "docs/account-picker-design/1-auto-account.png" },
    { "id": "B", "title": "One picker", "path": "docs/account-picker-design/2-one-picker.png" },
    { "id": "C", "title": "Account pools", "path": "docs/account-picker-design/3-pools.png" },
    { "id": "D", "title": "Moving mid-thread", "path": "docs/account-picker-design/4-moving-mid-thread.png", "reference": true }
  ]
}
```

The tool returns promptly. Mike's choice and notes arrive as a later message
in the same thread. Existing Codex native sessions may retain the tools they
started with; `tb rpc reviews.create '<JSON with threadId and the same fields>'`
can create a review for such a session once the runner has updated.

Click the transcript card to open the window. Click an image to enlarge it.
Enlarged, the title bar's magnifier switches between fit and 100%, one source
pixel per screen pixel with scrollbars. The arrow keys browse outside a note
box, Return enlarges or goes back, Esc goes back and Cmd-Return sends.
Reference images get notes but cannot be picked. The thread header also lists pending reviews, including those
older than the transcript page currently loaded.

Pick/unpick and notes save a draft. Closing the window keeps it; Send commits all the notes and optional choice together. A local
cache preserves text during a lost connection, including a rapid close and
reopen. If another window has changed the server draft, local text is kept
and an explicit Save my draft is needed before replacing it. Cancel review
closes the request without messaging the agent. An answered card reopens the
images and sent notes read-only.

Runner files: `runner/src/reviews.ts`, the review methods in `runner.ts`,
and the shared MCP tool in `threadbear-mcp.ts`. App files: core review models
and reduction, `ReviewSession.swift`, `ReviewRowCell.swift` and
`Views/ReviewWindow.swift`. `app/Tools/screenshots.sh /tmp/review-shots --only 16`
captures the card, all of them, a pick with a note, enlarged and 100% using the
four original images. The mock fixture is `demo_design_review`. See the app README for the
`review` automation command. HTML previews and overlays remain deferred.
