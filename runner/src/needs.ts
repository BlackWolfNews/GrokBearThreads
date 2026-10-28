// What a finished turn needs from Mike (docs/protocol.md, "Needs you"):
// the agent's end_turn call, or failing that the "What I need from you"
// section his own instructions ask every agent to end with. No model call:
// the agent that did the work is the one that knows.

import type { Ask, NeedsWho } from './protocol.ts';

export type Needs = { needs: NeedsWho; asks?: Ask[] };

export const END_TURN_TOOL = 'end_turn';

// Big enough for any real list; an agent that sends more is rambling.
const MAX_ASKS = 10;
const MAX_ACTION = 500;
const MAX_SHORT = 200;
// A decision with more than this many choices is better as a question.
const MAX_OPTIONS = 6;

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
export const END_TURN_DESCRIPTION =
  'Says whether Mike has to do anything now that this turn is over, so Threadbear can put the thread in Needs you or leave it as done. ' +
  'Call it once, as the very last thing in every turn, after your final message, and write nothing after it. ' +
  'needs "nothing" when the work is finished (or still going by itself) and nothing waits on Mike. ' +
  'needs "you" when it does: an approval, a decision, a key, something to look at, a question. Give one ask per thing he has to do, each a concrete action, most blocking first. ' +
  'Mike answers the asks one at a time in a card under your message, so write each as a short question or action that makes sense on its own, without reading the message. ' +
  'Give why: one line of context he would need if he had forgotten the details. ' +
  'Give options whenever there are likely answers (2 to 4 short ones, e.g. ["Merge", "Test locally first"]), and suggested: the index of the one you would pick. He can always write his own answer instead. ' +
  'For a step he has to do himself, offer options like ["Done", "Can you do it?"] when you could plausibly do it yourself. ' +
  'archive: true archives this thread once the turn is over, with needs "nothing" only. Use it only when Mike asks for this thread to be archived; otherwise leave it out, as a thread that vanishes from his inbox when he hadn\'t finished with it is confusing. ' +
  'Sub-agents never call this; only the thread\'s own agent does.';
