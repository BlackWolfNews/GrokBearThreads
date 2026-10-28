// The "Recent messages" part of a handoff note: what a fresh session on
// another login or provider is told about the thread so far. Modelled on
// T3 Code's handoff budget (packages/provider-core/src/server/handoffBudget.ts):
// messages and the work between them (commands with a little of their
// output, files edited, errors), not just the chat, so a model taking over
// mid-task knows what was already tried. The last user message, the last
// reply and the thread's first message go in first; the rest fill the
// budget from newest to oldest. Shown in the order they happened.
import type { PersistedEvent } from './protocol.ts';

export const HANDOFF_BUDGET = 16000;
const MESSAGE_CHARS = 2000;
const OUTPUT_CHARS = 300;

type Item = { seq: number; text: string; role: 'user' | 'assistant' | 'work' };

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n) + '…' : s);

// One item per message, tool call (with its result folded in) and edited
// file, oldest first. `skipTurnId`'s own user message is left out: it
// follows the note.
export function historyItems(events: PersistedEvent[], skipTurnId?: string): Item[] {
  const items: Item[] = [];
  const calls = new Map<string, Item>();
  const edited = new Set<string>();
  for (const e of events) {
    if (e.type === 'user.message') {
      if (skipTurnId && e.turnId === skipTurnId) continue;
      items.push({ seq: e.seq, role: 'user', text: `User: ${clip(e.text, MESSAGE_CHARS)}` });
    } else if (e.type === 'assistant.text') {
      if (e.text.trim()) items.push({ seq: e.seq, role: 'assistant', text: `Assistant: ${clip(e.text, MESSAGE_CHARS)}` });
    } else if (e.type === 'tool.call') {
      // Threadbear's own end_turn says nothing about the work.
      if (e.name.endsWith('end_turn')) continue;
      const item: Item = { seq: e.seq, role: 'work', text: `Tool: ${clip(e.title, 200)}` };
      calls.set(e.itemId, item);
      items.push(item);
    } else if (e.type === 'tool.result') {
      const call = calls.get(e.itemId);
      const out = e.text.trim();
      if (call && (out || !e.ok)) call.text += `\n  ${e.ok ? '→' : 'failed:'} ${clip(out, OUTPUT_CHARS).replace(/\n/g, '\n    ')}`;
    } else if (e.type === 'edit.diff') {
      // Once per file per edit: the same file edited again later shows again.
      const key = `${e.itemId}:${e.path}`;
      if (edited.has(key)) continue;
      edited.add(key);
      items.push({ seq: e.seq, role: 'work', text: `Edited: ${e.path}` });
    } else if (e.type === 'error') {
      items.push({ seq: e.seq, role: 'work', text: `Error: ${clip(e.message, 500)}` });
    }
  }
  return items;
}

// The items that fit in `budget` characters, in the order they happened,
// and how many were left out.
export function selectHistory(items: Item[], budget = HANDOFF_BUDGET): { lines: string[]; omitted: number } {
  const picked = new Set<Item>();
  let left = budget;
  const take = (item: Item | undefined) => {
    if (!item || picked.has(item)) return true;
    const cost = item.text.length + 2;
    if (cost > left) return false;
    left -= cost;
    picked.add(item);
    return true;
  };
  const last = (role: Item['role']) => items.findLast((i) => i.role === role);
  take(last('user'));
  take(last('assistant'));
  take(items.find((i) => i.role === 'user'));
  for (let i = items.length - 1; i >= 0; i--) if (!take(items[i])) break;
  // A gap (the first message, then the recent end) is marked, so the
  // model doesn't read two far-apart items as one exchange.
  const lines: string[] = [];
  let gap = false;
  for (const i of items) {
    if (!picked.has(i)) gap = lines.length > 0 || gap;
    else {
      if (gap) lines.push('[…]');
      gap = false;
      lines.push(i.text);
    }
  }
  return { lines, omitted: items.length - picked.size };
}
