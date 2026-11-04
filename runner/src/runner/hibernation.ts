// Snoozing and hibernating: when a thread wakes, by time, by topic or by restart.
// Part of the Runner (runner.ts), split out on 4 Nov 2026 as a plain move so a
// fork's change to one area doesn't clash with another's. Each method's `this`
// is the Runner; runner.ts puts them on its prototype.
import type { Runner } from '../runner.ts';
import type { RunnerPart } from './part.ts';
import type { ThreadSummary } from '../protocol.ts';
import { ErrorCode, RpcError } from '../protocol.ts';
import { SAID_MAX, WAKE_SYSTEM, awayFor, hibernateNote, readWakeAnswer, wakePrompt } from '../wake-when.ts';
import type { ThreadState } from '../runner.ts';
import { NO_WAKE_TIME } from '../runner.ts';

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
    st.rec.forceUnread = true;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.kickQueue(st);
  },
};

export type HibernationPart = RunnerPart<typeof hibernationPart>;
