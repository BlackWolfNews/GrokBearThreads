# Agent guidance for threadbare

Threadbare is Mike's own agent app: a TypeScript runner daemon (`runner/`)
that drives the official Claude Code (and later Codex) CLIs, and a native
SwiftUI + AppKit Mac app (`app/`) that talks to it over the protocol in
`docs/protocol.md`. Read `docs/plan.md` and `docs/protocol.md` before changing
anything.

## Rules

- Test first for anything non-trivial. Runner: `npm test` in `runner/`.
  App: `swift test` in `app/`.
- The protocol is the contract. Change `docs/protocol.md` first, then both
  sides, and keep both sides tolerant of unknown fields and event types.
- Only ever spawn the official `claude` (and later `codex`) binaries under
  Mike's own logins. Never read or copy OAuth tokens or Keychain credentials.
- Tests that hit a real model use the cheapest model, tiny prompts, a temp
  working folder and a temp runner data dir, never the real one.
- Never kill processes you didn't start; T3 Code runs the same CLIs.
- Screenshots: capture the app window only (by window id), never the full
  screen, and delete them when done unless they're for a PR.
- UI copy: plain words, no eyebrow or kicker labels, no em dashes.
- Transcript files and fixtures made from real sessions are private: keep them
  out of git (`.fixtures/` is ignored).
- Mike's own repo: commit to main once tests pass.
