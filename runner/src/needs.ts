// What a finished turn needs from Mike (docs/protocol.md, "Needs you"):
// the agent's end_turn call, or failing that the "What I need from you"
// section his own instructions ask every agent to end with. No model call:
// the agent that did the work is the one that knows.

import type { Ask, AskLink, NeedsWho, PersistedEvent } from './protocol.ts';

export type Needs = { needs: NeedsWho; asks?: Ask[] };

export const END_TURN_TOOL = 'end_turn';
// As the CLIs name it: under threadbear-mcp.ts's SERVER_NAME, which lives
// here too so the adapters needn't import the server.
export const END_TURN_FULL_NAME = `mcp__threadbear__${END_TURN_TOOL}`;

// Big enough for any real list; an agent that sends more is rambling.
const MAX_ASKS = 10;
const MAX_ACTION = 500;
const MAX_SHORT = 200;
// A decision with more than this many choices is better as a question.
const MAX_OPTIONS = 6;
// A button or two to go and do the thing; past three it's a reading list.
const MAX_LINKS = 3;
const MAX_URL = 2000;
// Web pages, and paths on this Mac. Anything else (javascript:, custom
// schemes) isn't something a button should open.
const LINK_URL = /^(?:https?:\/\/|file:\/\/|\/|~\/)/i;

// end_turn's input, checked. Undefined when it isn't usable, so the turn
// falls back to the text.
export function needsFromTool(input: unknown): Needs | undefined {
  if (!input || typeof input !== 'object') return undefined;
  const o = input as Record<string, unknown>;
  if (o.needs !== 'you' && o.needs !== 'nothing') return undefined;
  if (o.needs === 'nothing') return { needs: 'nothing' };
  const asks: Ask[] = [];
  for (const a of Array.isArray(o.asks) ? o.asks : []) {
    if (!a || typeof a !== 'object') continue;
    const r = a as Record<string, unknown>;
    const action = str(r.action, MAX_ACTION);
    if (!action) continue;
    const ask: Ask = { action };
    const where = str(r.where, MAX_SHORT);
    if (where) ask.where = where;
    const reply = str(r.reply, MAX_SHORT);
    if (reply) ask.reply = reply;
    const why = str(r.why, MAX_ACTION);
    if (why) ask.why = why;
    const options = (Array.isArray(r.options) ? r.options : []).map((o) => str(o, MAX_SHORT)).filter((o): o is string => !!o).slice(0, MAX_OPTIONS);
    if (options.length) {
      ask.options = options;
      // Only an index that points at one of them; anything else is no pick.
      const s = r.suggested;
      if (typeof s === 'number' && Number.isInteger(s) && s >= 0 && s < options.length) ask.suggested = s;
    }
    const links = linksFrom(r.links);
    if (links.length) ask.links = links;
    asks.push(ask);
    if (asks.length === MAX_ASKS) break;
  }
  return asks.length ? { needs: 'you', asks } : { needs: 'you' };
}

// Whether end_turn asked for its thread to be archived once the turn is
// over. Only with needs "nothing": a thread that's waiting on Mike has to
// stay where he'll see it.
export function archiveFromTool(input: unknown): boolean {
  if (!input || typeof input !== 'object') return false;
  const o = input as Record<string, unknown>;
  return o.needs === 'nothing' && o.archive === true;
}

function linksFrom(v: unknown): AskLink[] {
  const out: AskLink[] = [];
  for (const l of Array.isArray(v) ? v : []) {
    if (!l || typeof l !== 'object') continue;
    const r = l as Record<string, unknown>;
    const title = str(r.title, MAX_SHORT);
    const url = str(r.url, MAX_URL);
    if (!title || !url || !LINK_URL.test(url)) continue;
    out.push({ title, url });
    if (out.length === MAX_LINKS) break;
  }
  return out;
}

function str(v: unknown, max: number): string | undefined {
  if (typeof v !== 'string') return undefined;
  const t = v.trim();
  return t ? t.slice(0, max) : undefined;
}

// The heading starts a line, in bold or as a # heading (a plain mention in
// a sentence isn't one), with a colon either side of the ** or none.
// Text after it on the same line ("**What I need from you:** nothing right
// now") is the section's first line.
const HEADING = /^\s*(#{1,6}\s+)?(\*\*)?\s*What I need from you\s*:?\s*(\*\*)?\s*:?\s*(.*)$/i;
// Without a heading, a closing "Nothing needed from you right now" says it.
const NOTHING_LINE = /(?:^|[.!]\s+|\band\s+)\**\s*nothing (?:else )?(?:is )?needed from you\b/i;
const ITEM = /^(\s*)(\d{1,2}[.)]|[-*•])\s+(.*)$/;
const NOTHING = /\bnothing\b(?:[^.\n]{0,40}\b(?:needed|from you|for you to do)\b|\s+(?:right now|for now|yet)\b)/i;
// How far from the end the heading may be: agents sometimes quote it
// earlier in a message, and the real one closes it.
const NEAR_END_LINES = 40;

// The section in a final message, or undefined when there isn't one.
export function needsFromText(text: string): Needs | undefined {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  let at = -1;
  let first = '';
  for (let i = lines.length - 1; i >= 0 && i >= lines.length - NEAR_END_LINES; i--) {
    const m = HEADING.exec(lines[i]);
    if (m && ((m[2] && m[3]) || (m[1] && !m[2]))) {
      at = i;
      first = m[4].trim();
      break;
    }
  }
  if (at < 0) {
    const tail = lines.slice(-NEAR_END_LINES);
    return tail.some((l) => NOTHING_LINE.test(l)) ? { needs: 'nothing' } : undefined;
  }
  const body = lines.slice(at + 1);
  const items: string[] = [];
  const prose: string[] = first ? [first] : [];
  let inItem = false;
  let inFence = false;
  // The list's own kind (numbered or bulleted) and indent, from its first
  // item. A deeper item, or one of the other kind ("Pick one:" then its
  // choices), belongs to the ask above it.
  let top: { indent: number; numbered: boolean } | undefined;
  for (const line of body) {
    if (/^\s*```/.test(line)) inFence = !inFence;
    const m = inFence ? null : ITEM.exec(line);
    if (m) {
      const kind = { indent: m[1].length, numbered: /\d/.test(m[2]) };
      top ??= kind;
      if (items.length && (kind.indent > top.indent || kind.numbered !== top.numbered)) items[items.length - 1] += ` ${m[3]}`;
      else items.push(m[3]);
      inItem = true;
    } else if (!line.trim()) {
      // A blank line ends an item's continuation, not the list: items are
      // often a blank line apart.
      inItem = false;
    } else if (inItem || inFence || (items.length && /^\s{2,}\S/.test(line))) {
      items[items.length - 1] += ` ${line.trim()}`;
      inItem = true;
    } else if (!items.length) {
      prose.push(line.trim());
    } else {
      // Prose after the list (what the agent will do meanwhile) isn't an ask.
      break;
    }
  }
  if (!items.length) {
    const para = prose.join(' ').trim();
    if (!para || NOTHING.test(para)) return { needs: 'nothing' };
    return { needs: 'you', asks: [askFrom(para)] };
  }
  if (items.length === 1 && NOTHING.test(items[0])) return { needs: 'nothing' };
  return { needs: 'you', asks: items.slice(0, MAX_ASKS).map(askFrom) };
}

// "Open X, add Y, then reply 'done'" names the words to send back.
const REPLY = /\b(?:reply|send(?: back)?|say|answer|respond)(?: with)?\s+["'“‘`]([^"'”’`\n]{1,40})["'”’`]/i;

function askFrom(item: string): Ask {
  const action = item
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_ACTION);
  const ask: Ask = { action };
  const reply = REPLY.exec(action);
  // 'Reply "filter" or "wait"' is a choice, not the words to send back.
  if (reply && !/^\s*(?:or|,|\/)\s*["'“‘`]/.test(action.slice(reply.index + reply[0].length))) ask.reply = reply[1].trim();
  return ask;
}

// end_turn's description doubles as the instructions: a resumed Claude
// session keeps the system prompt it started with, but sees every tool's
// description afresh.
const END_TURN_WHAT =
  'Says whether Mike has to do anything now that this turn is over, so Threadbear can put the thread in Needs you or leave it as done. ';

// What to put in it, the same for both providers.
const END_TURN_ASKS =
  'needs "nothing" when the work is finished (or still going by itself) and nothing waits on Mike. ' +
  'needs "you" when it does: an approval, a decision, a key, something to look at, a question. Give one ask per thing he has to do, most blocking first. ' +
  'The asks are your "What I need from you" list: Mike reads and answers them in a card under your message, each drawn as one paragraph of message text, its action then its why, with its buttons under it. So don\'t also list them in your message. ' +
  'Write each ask the way you would in that list, so it makes sense on its own to someone who has forgotten everything: action is its first sentence, the thing to do or the question ("Next time you leave the room, take your phone and leave the laptop idle on power."); why carries on the same paragraph with what it is about and what you want back, in a sentence or two ("It should lock within a minute of you going. Tell me whether it did, and I\'ll tune the Bluetooth cutoff."). Say where in it when it matters (System Settings › Bluetooth), and name things rather than places (not "Slack #channel", but "Your Slack draft to Emily names the automation guy Hayden; he is Pete"). ' +
  'Give links whenever there is somewhere to go to do it or judge it: the page to log in on, the Slack message (its permalink), the PR, the preview, the file or screenshot to look at, the project to open (a path opens in its own app, e.g. a .tandem file in Tandem). Each is a button on the ask, so title it as the action ("Open login page", "Open the Slack message", "Open Short 4 in Tandem"). ' +
  'Every decision or yes/no question needs options: 2 to 4 short likely answers, e.g. ["Go", "Not yet"] or ["Merge", "Test locally first"], with suggested: the index of the one you would pick. "Say go for X, or name another" is a decision too: give ["Go", ...the other candidates]. Mike can always write his own answer instead, so options never box him in. ' +
  'For a step he has to do himself, offer options like ["Done", "Can you do it?"] when you could plausibly do it yourself. ' +
  'archive: true archives this thread once the turn is over, with needs "nothing" only. Use it only when Mike asks for this thread to be archived; otherwise leave it out, as a thread that vanishes from his inbox when he hadn\'t finished with it is confusing. ' +
  'Sub-agents never call this; only the thread\'s own agent does.';

export const END_TURN_DESCRIPTION =
  END_TURN_WHAT +
  'Call it once, as the very last thing in every turn, after your final message, and write nothing after it. ' +
  "It is refused until the turn has a reply: ordinary text from you after your last tool result (Threadbear's own tools aside), so Mike gets a complete answer in the conversation. " +
  END_TURN_ASKS;

// Codex's: its final answer ends the turn, so nothing can be called after
// it. Told to call end_turn after its final message, Codex never once
// did; GPT-6.1-Sol wrote the call into its final answer instead, raw
// tool-call tokens and all, and Mike read them (28 Oct 2026).
export const CODEX_END_TURN_DESCRIPTION =
  END_TURN_WHAT +
  'Call it once, as your last tool call, just before your final answer: the final answer ends the turn, so nothing can be called after it. ' +
  'Call it through your tools like any other; never write the call, or its result, in your message. ' +
  END_TURN_ASKS;

// What end_turn says when the turn has no reply yet. An error result, so
// the CLI doesn't take the call as the end of the turn (adapter.ts,
// CLAUDE_CODE_TERMINAL_MCP_TOOLS) and the agent reads it. Ask for the whole
// answer, as a shorter reminder once got Mike only a closing line.
// Describe the result he needs: wording that asks for internal reasoning
// can trigger a provider safeguard even during ordinary work.
export const NO_REPLY =
  "Not ended: Mike hasn't had a reply this turn after his latest message and your latest tool result. " +
  'Please write the whole answer as ordinary text, with the result and any supporting evidence Mike needs. Then call end_turn again.';

// How every accepted end_turn result starts, so the runner can tell one
// from a refusal by what it says (a refusal's ok flag is only as good as
// the provider's) and drop text written after it.
export const ENDED = 'Noted: this thread';

export function endTurnAccepted(result: { ok: boolean; text: string }): boolean {
  return result.ok && result.text.startsWith(ENDED);
}

// Whether the turn so far has given Mike a reply, for end_turn to check
// before it ends the turn. An agent that drafted its answer in thinking
// and went straight to end_turn left him a folded work group and a card
// of asks, twice in one thread (28 Oct 2026). `events` are the thread's
// recent ones, oldest first; only those after the last turn.started count.
export type TurnReply = {
  // This end_turn call has reached the events (a tool.call for it with no
  // result yet). The CLI writes a call before it runs the tool, so once it
  // is there, so is everything the agent said before it.
  landed: boolean;
  // The agent's own assistant.text after its last tool result from a tool
  // outside the threadbear server, and after the last message from Mike in
  // the turn. The thread's own tools (pin, update_project, an earlier
  // refused end_turn) say nothing he has to read, so a message, then pin,
  // then end_turn is a turn that replied.
  replied: boolean;
};

// Tools that do nothing Mike would want told about. ToolSearch loads a
// deferred tool's schema (end_turn's, as often as not: "Hello.", then
// ToolSearch for end_turn, then end_turn was refused for having worked
// since the reply).
const PLUMBING_TOOLS = new Set(['ToolSearch']);

export function turnReply(events: PersistedEvent[], serverName = 'threadbear'): TurnReply {
  const ownPrefix = `mcp__${serverName}__`;
  const endTurn = `${ownPrefix}${END_TURN_TOOL}`;
  let start = 0;
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].type === 'turn.started') {
      start = i + 1;
      break;
    }
  }
  const names = new Map<string, string>();
  const open = new Set<string>(); // end_turn calls with no result yet
  let lastText = 0;
  let lastWork = 0;
  let lastUser = 0;
  for (const e of events.slice(start)) {
    // A Codex child's items carry its prefix (<child>/<id>); Claude's
    // sub-agents never reach the thread's events.
    if ('itemId' in e && typeof e.itemId === 'string' && e.itemId.includes('/')) continue;
    switch (e.type) {
      case 'user.message':
        lastUser = e.seq;
        break;
      case 'assistant.text':
        lastText = e.seq;
        break;
      case 'tool.call':
        names.set(e.itemId, e.name);
        if (e.name === endTurn) open.add(e.itemId);
        break;
      case 'tool.result': {
        const name = names.get(e.itemId);
        open.delete(e.itemId);
        if (name !== undefined && !name.startsWith(ownPrefix) && !PLUMBING_TOOLS.has(name)) lastWork = e.seq;
        break;
      }
      default:
        break;
    }
  }
  return { landed: open.size > 0, replied: lastText > 0 && lastText > lastWork && lastText > lastUser };
}
