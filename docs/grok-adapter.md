# Adding Grok Build to Threadbear

Notes from the public fork [BlackWolfNews/GrokBearThreads](https://github.com/BlackWolfNews/GrokBearThreads).
`main` stays even with [mikecann/threadbear](https://github.com/mikecann/threadbear).
The Grok work is on `grok`. This file is the log of that work: what we
changed, what was easy, what fought back, and what is still open. It is
meant to be read again when something breaks, and by anyone wiring a
different agent in beside Claude and Codex.

Threadbear is MIT, Copyright (c) 2026 Mike Cann. This fork keeps his
copyright and the MIT notice. The Grok adapter is additional work on
top of his.

Status on 2026-11-08: the runner can start a Grok thread, give it
Threadbear's tools, and open a Grok session that is already on disk.
One live `grok` 1.0.77 turn completed through the adapter. The Mac app
is not installed. See "Tried against the real CLI".

## What this is

A Threadbear thread runs one agent process. Claude goes through the
Claude Agent SDK. Codex goes through `codex app-server`. Grok goes
through `grok agent --no-leader stdio`, which is Grok Build's Agent
Client Protocol on newline-delimited JSON. One process per live thread.
Grok still does Grok's own work: read, edit, shell, and the MCP servers
and skills already in `~/.grok`. Threadbear adds a window around that
process, and a few tools of its own (`end_turn` and the rest) so the
inbox can file the thread.

A thread Threadbear starts is a new Grok session. It does not attach to
a terminal that is already open. The process also loads the MCP servers
already configured for that CLI. A session Grok already has on disk can
be opened as a thread. The next message is `session/load`. See "Opening
a session already on disk".

## How hard, so far

Wiring the name "grok" through the runner was an evening. The adapter
that speaks the protocol was a day against a fake process, then one live
turn. The tools were the hard part, and they are the part that will be
hard for the next agent too. Opening a session already on disk was the
resume flag the runner already had, plus a read of each `summary.json`.

The Mac app did not need a change. It stores `provider` as a string, and
an unknown provider is shown with a capital letter, so "grok" reads as
"Grok".

## Files that will hurt on the next merge

Mike ships often. These files are his, and a Grok edit in them will
conflict. Keep the edits small.

| File | What changed |
|---|---|
| `runner/src/protocol.ts` | `Provider` and `PROVIDERS` include `'grok'`. `docs/protocol.md` has the same line. An older app treats an unknown provider as a plain thread. |
| `runner/src/main.ts` | Builds `GrokAdapter` and puts it on `adapters.grok`, with `toolsFor` and `instructionsFor`. |
| `runner/src/accounts.ts` | If `grokMainDir` exists (default `~/.grok`), one account: `grok-main`, title "Grok". Grok has no Claude `settings.json`, so its model is left unset. |
| `runner/src/config.ts` | `grokPath` (`THREADBEAR_GROK_PATH`, else runner.json, else `grok`) and `grokMainDir` (`THREADBEAR_GROK_MAIN_DIR`, else `~/.grok`). |
| `runner/src/pools.ts` | `PROVIDER_TITLES.grok` is `Grok`. |
| `runner/src/net-probe.ts` | Grok's host is `api.x.ai`. |
| `runner/src/runner.ts` | A thread marked confined is refused with a Grok-specific sentence. Grok is not started inside Threadbear's sandbox. |
| `runner/src/runner/new-threads.ts` | `threads.create` takes `grokSessionId` and makes a thread that resumes that session. |
| `runner/src/rpc.ts` | `grok.sessions`, and `threads.create` passes `grokSessionId`. |
| `runner/src/cli.ts` | `tb grok sessions` and `tb grok open`. |
| `docs/protocol.md` | The same two: `grok.sessions`, and `grokSessionId` on `threads.create`. |
| `runner/src/updates/manager.ts` | Threadbear does not install or replace Grok. The policy stays off. A bare `grok` on `PATH` is reported as `unknown`, not `missing`, because `existsSync` cannot see a `PATH` command. |
| `runner/src/adapters/types.ts` | Comment only. The seam was already `AgentAdapter`. |

`runner/test/helpers/fakes.ts`, `protocol-check.ts`, and one assertion in
`updates.test.ts` moved with those types. The test config points
`grokPath` at a binary that is not there, so the suite never launches
Grok.

## Files that are only ours

`runner/src/adapters/grok/` merges cleanly. That is the whole connector.

| File | Role |
|---|---|
| `adapter.ts` | Spawns the process, speaks JSON-RPC, streams text and tool calls, answers permission requests. |
| `mcp-bridge.mjs` | The stdio MCP server Grok spawns. It has no tools of its own. |
| `tools.ts` | Listens on a unix socket, runs `buildThreadbearTools`'s handlers, records the call. |
| `sessions.ts` | Reads `summary.json` for each session under `~/.grok/sessions`. Does not read the conversation. |
| `runner/test/fixtures/fake-grok.mjs` | Stand-in process for the tests. |
| `runner/test/unit/grok-adapter.test.ts` | The connector. Seven tests. |
| `runner/test/unit/grok-sessions.test.ts` | The on-disk list, and opening one as a thread. |

## The connector

Spawn, unless a test passes its own command:

```
grok agent [--always-approve] [--model M] --no-leader stdio
```

`--always-approve` is added only for a thread in Full access.
`--no-leader` keeps this thread's process its own, rather than joining
the shared leader a terminal session may be using.

Then, over stdin/stdout, one JSON object per line:

1. `initialize` with `protocolVersion` 1. The live CLI reports its version as `_meta.agentVersion` (1.0.77 did). `agentInfo.version` is accepted too.
2. `session/new`, or `session/load` when the thread already has a Grok session id. Both get `cwd`, `mcpServers`, and `_meta`.
3. `session/prompt` with `prompt: [{ type: "text", text }]`.
4. Notifications `session/update` and `x.ai/session/update`. Chunks are `agent_message_chunk` and `agent_thought_chunk`. Tool calls are `tool_call` and `tool_call_update`.
5. A permission request is `session/request_permission`, with `toolCall` and options `allow_once`, `allow_always`, `reject_once`. The answer is `{ outcome: { outcome: "selected", optionId } }`, or `cancelled`.
6. `session/cancel` interrupts. `session/set_config_option` changes `model` and `reasoning_effort`. The value we send is a string id. Threadbear's `ultra` is Grok's `max`.

`_meta.rules` carries standing instructions. Full access sets
`yoloMode`, Auto sets `autoMode`. Plan mode has no flag. The adapter
puts "Plan only…" into the rules and again at the front of the prompt.

A permission mode is fixed for the life of the process
(`settingsApplyNextTurn`). Changing it applies on the next turn, which
starts a new process. Images are named in the prompt text. A folder
change is a handoff, not `setCwd`. Rewind is not implemented.

A resume whose error says the session was not found raises
`SessionNotFoundError`, and the runner starts a fresh session. A failed
open kills the process group. Leaving it alive keeps the runner waiting
on the pipes.

## Threadbear's tools, which were the hard part

The inbox builds a Needs you card only when it sees a tool call named
exactly `mcp__threadbear__end_turn` (`runner/src/runner.ts`). The tool's
handler is what actually snoozes, archives, and records the asks
(`runner/src/threadbear-mcp.ts`). Both have to happen. The handler waits
up to a second for its own call to show up in the thread's event log
before it judges the turn, so the adapter records the call before it
runs the handler.

Claude gets those tools from an in-process MCP server built with
`@anthropic-ai/claude-agent-sdk`. That server cannot be handed to Grok.
Codex gets the same handlers as dynamic tools on `thread/start`. Grok's
way is the `mcpServers` array on `session/new` and `session/load`. Grok
spawns the server. The shape that matches the Agent Client Protocol is:

```json
{
  "name": "threadbear",
  "command": "/absolute/path/to/node",
  "args": ["/absolute/path/to/mcp-bridge.mjs", "/tmp/tb-grok-….sock"],
  "env": []
}
```

`env` is a list of `{ "name", "value" }`, and an empty list is sent.
`command` is absolute. The bridge speaks MCP on stdio and forwards
`tools/list` and `tools/call` over the socket. The socket is mode `0600`
and removed when the thread ends.

Grok also announces the same call on `session/update`. On the live CLI
that announcement is its own `use_tool` call, with the tool name in
`rawInput.tool_name` (`end_turn`, then `threadbear__end_turn`, then the
bridge runs). The adapter drops that copy when the title, the name, or
`rawInput.tool_name` is one of the thread's tools. Recording it twice
would move the card.

Two schema shapes come out of `buildThreadbearTools`. Most tools carry
a zod raw shape. `end_turn` carries a whole zod object. `tools.ts`
checks for `_zod` and converts either one. This is the same split
`context-budget.test.ts` already knew about.

Tools that always ask (`delete_thread`) and tools that change something
outside Full access go through the same approval card as Claude and
Codex. `end_turn` does not ask. An "always allow" answer is stored on
the thread as `allowRules`.

The tool descriptions use Claude's wording. Grok calls the tool in the
same turn as its message. Codex's wording is for a final answer that
arrives on its own channel.

## What the tests cover

`runner/test/unit/grok-adapter.test.ts`, against `fake-grok.mjs`:

- a new session streams text and reports the session id
- a permission request becomes the same card, and the answer goes back
- a missing resume is reported so the runner can start fresh
- `end_turn` is recorded once, as `mcp__threadbear__end_turn`, before the handler runs, and Grok's own copy of that call is dropped
- `delete_thread` is refused before its handler runs
- the real tool list converts to JSON Schema, including `end_turn`
- `grok-main` is discovered from a directory

`npx tsc` is not the check. The runner has its own TypeScript, and
`erasableSyntaxOnly` rejects parameter properties (`constructor(private
x)`). Assign the fields in the body. Run
`./node_modules/.bin/tsc --noEmit -p .` from `runner/`, and
`node --test test/unit/grok-adapter.test.ts test/unit/grok-sessions.test.ts`.

## Opening a session already on disk

`grok sessions list` only shows the folder it was started in. The
sessions themselves live under `~/.grok/sessions/<encoded-cwd>/<id>/`.
`sessions.ts` reads each `summary.json` and nothing else. `updates.jsonl`
is the conversation, and it stays unread. The title is `generated_title`,
or else `session_summary`. The folder is `info.cwd`, or else the `.cwd`
file beside the session folders, or else the decoded directory name.
A symlink that leaves the sessions directory is skipped.

`tb grok sessions` prints that list without a running runner.
`grok.sessions` is the same list on the socket. `tb grok open <id>` and
`threads.create` with `grokSessionId` make a thread whose folder, title,
and native session id are the ones in the summary, and whose
`sessionUsed` is set, so the next message is `session/load`. With no
text the thread waits. The account is `grok-main` when none is named.
A pool is refused. A `cwd` that is not the session's folder is refused.
A thread that already has that session id is refused.

The turns from before the open stay in Grok. Threadbear's window starts
empty. Inbox buttons apply to turns after the thread exists. A session
that is still open in a terminal fails that load. The error does not
look like "session not found", so the runner does not start a second
copy. Nothing here imports every session on its own. The Mac app has
no list of its own yet.

## Still open

- The full Threadbear tool list on a live CLI. One stub `end_turn` has been called for real. `session/set_config_option` has not.
- Copying the earlier turns out of `updates.jsonl` into the thread, so the window is not empty until the next message. The Mac app's own session list.
- The librarian. It still runs as `claude -p`. Leave `models.pool` null until it can call Grok.
- `./threadbear setup`. It still expects `claude` or `codex` on `PATH`.
- Building the Mac app. `xcode-select` on the machine this was written on still points at the Command Line Tools, not Xcode.
- Bundle id, LaunchAgent label, and menu-bar name. They stay `com.mikerosoft.threadbear` until the install that should be kept. Renaming after that install leaves the old agent and preferences behind. `docs/forking.md` is Mike's note on this.
- Images as image blocks, rewind, and moving a live session to another folder.

## Tried against the real CLI

2026-11-08, `grok` 1.0.77, one turn, through `GrokAdapter` with the real
binary. The folder was a temporary directory, so the session is filed
under that path in `~/.grok/sessions/`, not under a project. The prompt
asked for the word hello and one `end_turn`. Permission mode was Ask,
and any tool other than the stub `end_turn` would have been denied.
None was asked.

What happened:

- `initialize` succeeded. `loadSession` was advertised. Image prompts
  were advertised. The version was `_meta.agentVersion`, so the adapter
  now reads that field.
- `session/new` accepted the stdio `mcpServers` entry. The bridge
  started, listed `end_turn`, and ran it. The turn outcome was
  `completed`. The recorded call was `mcp__threadbear__end_turn` with
  `needs: "nothing"` and `summary: ["said hello"]`.
- Before that, Grok called its own `use_tool` twice, first as `end_turn`
  and then as `threadbear__end_turn`. Those rows are the same call. The
  adapter now drops them.
- The model wrote the word hello once per attempt, so the reply text was
  the word three times. That is the model finding the tool name, not the
  stream being delivered twice.
- The process used the CLI's current model. This one reported Grok 4.7.
- A separate `initialize`, with no session, also showed the MCP servers
  already configured for the CLI. A Threadbear thread gets those as well
  as the `threadbear` server.

The stub tool was one hand-written `end_turn`, so this run did not
exercise the full Threadbear tool list against the live CLI. The unit
test still checks that the real list converts to JSON Schema. The
session id was `01a1ba30-7306-7f91-b9ff-2baa5b9a1fc6`.
