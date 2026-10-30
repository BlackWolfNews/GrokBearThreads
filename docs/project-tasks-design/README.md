# Project tasks from Notion (30 Oct 2026)

Mike: projects should be able to have a Notion page that tracks tasks as a
kanban, like the Port Geo one (the "Christmas Lights 2026 (shared with
ARG)" page), with the board shown back on the project page.

Three directions, all drawn with Port Geo's real open items from that page:

1. **Notion owns the board, Threadbear mirrors it.** A Tasks database on
   each project's Notion page. People and agents edit it in Notion (agents
   through the Notion connector); the runner reads it through the
   Connectors gateway every few minutes and the project page shows it
   read-only.
2. **Threadbear owns the board, Notion gets a copy.** Tasks are a project
   field. A card can start a thread, and the thread's state moves the card.
   The runner writes it to Notion so others can see it, and reads their
   changes back (two-way sync, the expensive part).
3. **The Notion page is the brief.** No database: Threadbear reads the
   to-dos on the project's plain Notion page and lists what's open by
   person, with the page in the side pane. Could be a patch.

`zsh render.sh` redraws the PNGs.
