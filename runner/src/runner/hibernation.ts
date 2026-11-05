// Snoozing and hibernating: when a thread wakes, by time, by topic or by restart.
// Part of the Runner (runner.ts), split out on 4 Nov 2026 as a plain move so a
// fork's change to one area doesn't clash with another's. Each method's `this`
// is the Runner; runner.ts puts them on its prototype.
import type { Runner } from '../runner.ts';
import type { RunnerPart } from './part.ts';
import type { ThreadSummary } from '../protocol.ts';
import { ErrorCode, RpcError } from '../protocol.ts';
import { SAID_MAX, WAKE_SYSTEM, awayFor, hibernateNote, localWhen, readWakeAnswer, wakePrompt } from '../wake-when.ts';
import type { ThreadState } from '../runner.ts';
import { NO_WAKE_TIME } from '../runner.ts';
import { parseWhen } from '../when.ts';

// How long a thread waiting on others sleeps at most when end_turn gave no
// snooze, so one that never hears still comes back.
export const WAIT_FOR_DEFAULT_MS = 86_400_000;
// How much of each finished thread's reply the waiting one is handed.
export const WAIT_FOR_REPLY_CHARS = 2000;

export const hibernationPart = {
  // Hibernates a thread until when Mike said, in his own words
  // (wake-when.ts), as Opus reads them: a time, a topic for the librarian
  // to listen for, or both. The thread goes away at once, as a preset
  // does, and the time follows once the model answers; if it can't say,
  // the thread comes back and the call fails with why.
  async hibernateWhen(this: Runner, params: { threadId: string; said: string }): Promise<{ thread: ThreadSummary; until?: string; topic?: string; why: string }> {
    const st = this.mustGet(params.threadId);
    const said = params.said.trim();
    if (!said) throw new RpcError(ErrorCode.badParams, 'Say when it should wake.');
    if (said.length > SAID_MAX) throw new RpcError(ErrorCode.badParams, `That's more than ${SAID_MAX} characters.`);
    const models = this.models;
    if (!models) throw new RpcError(ErrorCode.other, 'Model calls are off in this runner.');
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const gist = this.threadGist(st.rec.id, { recent: 0 });
    const input = { said, now: this.clock.now(), timeZone, title: st.rec.title, first: gist.first, brief: st.rec.brief?.text };
    this.update({ threadId: st.rec.id, snoozedUntil: NO_WAKE_TIME });
    st.rec.wakeWhen = { said, pending: true };
    this.markDirty(st);
    const ask = (withThread: boolean) =>
      models.generate({
        feature: 'wake-when',
        ...(withThread ? { cwd: st.rec.cwd } : {}),
        system: WAKE_SYSTEM,
        prompt: wakePrompt(withThread ? input : { said, now: input.now, timeZone, title: '(private)' }),
        maxTokens: 300,
        strong: true,
      });
    let res = await ask(true);
    // A private folder's thread isn't sent: his words alone are usually enough.
    if (!res.ok && res.reason === 'private') res = await ask(false);
    // Woken, hibernated another way or deleted meanwhile: that wins.
    if (st.rt.deleted || st.rec.wakeWhen?.pending !== true || st.rec.wakeWhen.said !== said) {
      throw new RpcError(ErrorCode.other, 'The thread was woken or put away again while this was worked out.');
    }
    const answer = res.ok ? readWakeAnswer(res.value, this.clock.now()) : { error: res.message || `No answer from the model (${res.reason}).` };
    if ('error' in answer) {
      delete st.rec.snoozedUntil;
      delete st.rec.wakeWhen;
      st.rec.updatedAt = this.isoNow();
      this.markDirty(st);
      this.armSnoozeTimer();
      this.kickQueue(st);
      throw new RpcError(ErrorCode.other, `Couldn't work out when to wake it: ${answer.error}`);
    }
    st.rec.snoozedUntil = answer.until ?? NO_WAKE_TIME;
    st.rec.wakeWhen = { said, ...(answer.topic ? { topic: answer.topic } : {}) };
    this.emit(st, { type: 'system.note', text: hibernateNote(answer, said, timeZone) });
    this.armSnoozeTimer();
    this.log.info('hibernated in words', { threadId: st.rec.id, until: answer.until, topic: answer.topic });
    return { thread: this.summary(st), ...answer };
  },

  // Threads hibernating until Mike next talks about something, for the
  // librarian to listen for.
  waitingTopics(this: Runner): { threadId: string; title: string; topic: string }[] {
    const now = this.clock.now();
    const out: { threadId: string; title: string; topic: string }[] = [];
    for (const { rec, rt } of this.threads.values()) {
      const topic = rec.wakeWhen?.topic;
      if (!topic || rt.deleted || rec.archivedAt || !rec.snoozedUntil || Date.parse(rec.snoozedUntil) <= now) continue;
      out.push({ threadId: rec.id, title: rec.title, topic });
    }
    return out;
  },

  // The librarian heard Mike talk about a hibernating thread's topic in
  // another thread: it wakes, unread, saying where.
  wakeForTopic(this: Runner, threadId: string, inThreadId: string): boolean {
    const st = this.threads.get(threadId);
    const topic = st?.rec.wakeWhen?.topic;
    if (!st || !topic || st.rt.deleted || st.rec.archivedAt || threadId === inThreadId || this.bucket(st.rec) !== 'snoozed') return false;
    const where = this.threads.get(inThreadId)?.rec.title;
    this.wake(st, { why: `you talked about ${topic}${where ? ` in "${where}"` : ' in another thread'}` });
    this.armSnoozeTimer();
    this.log.info('woke for a topic', { threadId, inThreadId, topic });
    return true;
  },

  // end_turn's waitFor, once the turn is over: hibernates until every
  // named thread finishes a turn with nothing left (or is archived or
  // deleted), then wakes with what they said. A thread that never hears
  // wakes at the snooze time, or after a day. Before 5 Nov 2026 a thread
  // waiting on another's report could only end as done, in the inbox.
  waitOn(this: Runner, st: ThreadState, ids: string[], when: string | undefined): void {
    const { rec } = st;
    const list: { threadId: string; title: string }[] = [];
    const skipped: string[] = [];
    for (const id of ids) {
      const hits = [...this.threads.values()].filter((t) => !t.rt.deleted && (t.rec.id === id || t.rec.id.startsWith(id)));
      const t = hits.length === 1 ? hits[0] : undefined;
      if (!t || t === st || t.rec.archivedAt) skipped.push(id);
      else if (!list.some((x) => x.threadId === t.rec.id)) list.push({ threadId: t.rec.id, title: t.rec.title });
    }
    if (!list.length) {
      this.emit(st, { type: 'system.note', text: `Not hibernated: none of the threads it was to wait on (${ids.join(', ')}) are here and still going.` });
      return;
    }
    const now = this.clock.now();
    let until: string | undefined;
    if (when && when.toLowerCase() !== 'restart') {
      try {
        until = parseWhen(when, now);
      } catch {
        until = undefined;
      }
    }
    if (!until || Date.parse(until) <= now) until = new Date(now + WAIT_FOR_DEFAULT_MS).toISOString();
    this.update({ threadId: rec.id, snoozedUntil: until });
    rec.waitingOn = list;
    this.markDirty(st);
    const names = list.map((x) => `"${x.title}"`).join(list.length === 2 ? ' and ' : ', ');
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const also = skipped.length ? ` (${skipped.join(', ')} isn't a thread here that's still going, so it isn't waited on.)` : '';
    this.emit(st, { type: 'system.note', text: `Hibernating until ${names} ${list.length === 1 ? 'finishes' : 'finish'}, or ${localWhen(Date.parse(until), timeZone)} at the latest.${also}` });
  },

  // A thread finished, or was archived or deleted: any hibernating thread
  // waiting on it marks it done, and the one whose waits are all done wakes
  // and carries on with their replies.
  waitedOnFinished(this: Runner, threadId: string, how: 'finished' | 'archived' | 'deleted'): void {
    for (const st of this.threads.values()) {
      const waits = st.rec.waitingOn;
      if (!waits || st.rt.deleted || st.rec.archivedAt || this.bucket(st.rec) !== 'snoozed') continue;
      const w = waits.find((x) => x.threadId === threadId && !x.done);
      if (!w) continue;
      w.done = { at: this.isoNow(), how };
      // The latest title, and the reply while it's there to read.
      const target = this.threads.get(threadId);
      if (target && !target.rt.deleted) w.title = target.rec.title;
      this.markDirty(st);
      if (!waits.every((x) => x.done)) continue;
      const parts = waits.map((x) => {
        const head = `"${x.title}" (thread ${x.threadId.slice(0, 8)})`;
        if (x.done?.how === 'deleted') return `${head} was deleted.`;
        let reply = '';
        try {
          reply = this.threadGist(x.threadId, { recent: 1, chars: WAIT_FOR_REPLY_CHARS }).recent.at(-1)?.text ?? '';
        } catch {
          reply = '';
        }
        const said = x.done?.how === 'archived' ? 'was archived' : 'finished';
        return reply ? `${head} ${said}. Its last reply:\n\n${reply}` : `${head} ${said}.`;
      });
      const why = waits.length === 1 ? `"${waits[0].title}" finished` : 'the threads it was waiting on finished';
      const text = `The thread${waits.length === 1 ? '' : 's'} you hibernated to wait on ${waits.length === 1 ? 'has' : 'have'} finished.\n\n${parts.join('\n\n')}\n\nCarry on from here. read_thread has the rest of ${waits.length === 1 ? 'it' : 'them'}.`;
      this.wake(st, { why });
      this.armSnoozeTimer();
      this.sendTo(st, text, [], { origin: 'runner', queue: true });
      this.log.info('woke after waiting on threads', { threadId: st.rec.id, on: waits.map((x) => x.threadId) });
    }
  },

  armSnoozeTimer(this: Runner): void {
    this.snoozeTimer?.cancel();
    this.snoozeTimer = undefined;
    if (this.stopping) return;
    const now = this.clock.now();
    let next = Infinity;
    for (const st of this.threads.values()) {
      if (!st.rec.snoozedUntil) continue;
      const t = Date.parse(st.rec.snoozedUntil);
      if (t <= now) this.wake(st, 'time');
      else next = Math.min(next, t);
    }
    if (next === Infinity) return;
    // Re-check at least hourly so long snoozes survive clock changes.
    this.snoozeTimer = this.clock.setTimeout(() => this.armSnoozeTimer(), Math.min(next - now, 3_600_000));
  },

  // A thread coming back by itself (its time, a restart, a topic) says so
  // in its conversation, with how long it was away, and its row says
  // "Woke up" until Mike looks (`woke`): otherwise it just turns up in the
  // inbox with nothing to say why (30 Oct).
  wake(this: Runner, st: ThreadState, cause: 'time' | 'restart' | { why: string }): void {
    const { rec } = st;
    const now = this.clock.now();
    const since = rec.snoozedAt && Date.parse(rec.snoozedAt) <= now ? rec.snoozedAt : undefined;
    // Under a minute (a wake-when cut short by a restart) isn't worth saying.
    const ms = since ? now - Date.parse(since) : 0;
    const away = ms >= 60_000 ? ` after ${awayFor(ms)}` : '';
    const text = typeof cause === 'object'
      ? `Woke up${away}: ${cause.why}.`
      : cause === 'restart'
        ? `Woke up${away}, as the runner restarted.`
        : away ? `Woke up after hibernating for ${awayFor(ms)}.` : 'Woke up from hibernating.';
    this.emit(st, { type: 'system.note', text });
    rec.woke = { at: new Date(now).toISOString(), ...(since ? { since } : {}) };
    delete rec.snoozedAt;
    delete st.rec.snoozedUntil;
    delete st.rec.snoozedUntilRestart;
    delete st.rec.wakeWhen;
    delete st.rec.waitingOn;
    st.rec.forceUnread = true;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.kickQueue(st);
  },
};

export type HibernationPart = RunnerPart<typeof hibernationPart>;
