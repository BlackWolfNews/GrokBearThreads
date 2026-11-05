// What a hibernating thread waits for, in a few words, when it's more than
// a time: "\"Convex I/O\" finishes", "you talk about woodworking", "the
// runner updates". The phone and the website show it on the row (synced as
// wakeNote, sync.ts), and the agent tools say it; the Mac app builds its
// own from the same fields (WakeWords in Snooze.swift). A time alone gives
// nothing, as each client says a time in its own way.
import type { ThreadSummary } from './protocol.ts';

export function wakeNote(t: Pick<ThreadSummary, 'waitingOn' | 'wakeWhen' | 'snoozedUntil' | 'snoozedUntilRestart' | 'snoozedUntilRelease'>): string | undefined {
  if (!t.snoozedUntil) return undefined;
  const left = (t.waitingOn ?? []).filter((w) => !w.done);
  if (left.length) {
    if (left.every((w) => !w.until)) return `${left.map((w) => `"${w.title}"`).join(left.length === 2 ? ' and ' : ', ')} ${left.length === 1 ? 'finishes' : 'finish'}`;
    return left.map((w) => `"${w.title}" ${w.until ?? 'finishes'}`).join('; ');
  }
  if (t.wakeWhen?.topic) return `you talk about ${t.wakeWhen.topic}`;
  if (t.snoozedUntilRelease) return 'the runner updates';
  if (t.snoozedUntilRestart) return 'the runner restarts';
  return undefined;
}
