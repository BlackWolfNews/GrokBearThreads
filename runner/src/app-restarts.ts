import fs from 'node:fs';
import path from 'node:path';
import type { Clock } from './clock.ts';
import type { Logger } from './log.ts';
import type { Runner } from './runner.ts';

// Telling a thread when the Mac app has restarted onto a new build
// (docs/protocol.md, "App restarts"). An agent that changed the app asks
// Mike to Restart to Update and ends its turn; the app says `hello` with
// its build when it comes back, and each thread waiting for that gets a
// note and a message, so it can check its change in the running app.

export type AppBuild = { commit: string; short: string; tree: string };

// `due`: the app has come back on this build, but the thread was on a
// draining runner then; it hears once it comes across (adopted).
type Watch = { threadId: string; text?: string; requestedAt: string; fromTree?: string; fromShort?: string; due?: AppBuild };
type SavedState = { build?: AppBuild; watching: Watch[] };

// After a day the request has likely been forgotten: only the note.
const MAX_AGE_MS = 24 * 60 * 60_000;

export function appRestartsPath(home: string): string {
  return path.join(home, 'app-restart.json');
}

// end_turn asks that tell Mike to restart the app onto an update count as
// asking to hear about it, so the agent needn't remember the tool.
export function asksForAppRestart(asks: { action?: unknown; why?: unknown; where?: unknown }[] | undefined): boolean {
  return (asks ?? []).some((a) => /restart to update/i.test(`${a.action ?? ''} ${a.why ?? ''} ${a.where ?? ''}`));
}

// `away`: whether a draining runner still has the thread (handover.ts's
// Peers), so it isn't here yet but will be.
type Deps = { runner: Pick<Runner, 'get' | 'note' | 'send' | 'has'>; home: string; clock: Clock; log: Logger; away?: (threadId: string) => boolean };

export class AppRestarts {
  private deps: Deps;

  constructor(deps: Deps) {
    this.deps = deps;
  }

  // Sends a message to the thread when the app next comes back on a build
  // other than the one running now. Asking again replaces the request.
  watch(threadId: string, text?: string): { build?: AppBuild } {
    const state = this.read();
    state.watching = state.watching.filter((w) => w.threadId !== threadId);
    state.watching.push({
      threadId,
      ...(text?.trim() ? { text: text.trim() } : {}),
      requestedAt: new Date(this.deps.clock.now()).toISOString(),
      ...(state.build ? { fromTree: state.build.tree, fromShort: state.build.short } : {}),
    });
    this.write(state);
    return state.build ? { build: state.build } : {};
  }

  isWatching(threadId: string): boolean {
    return this.read().watching.some((w) => w.threadId === threadId);
  }

  // The Mac app's `hello`, with the build it's running.
  appHello(build: AppBuild): void {
    const state = this.read();
    const { runner, log, away } = this.deps;
    const now: Watch[] = [];
    const kept: Watch[] = [];
    for (const w of state.watching) {
      if (w.fromTree === build.tree) kept.push(w);
      else if (runner.has(w.threadId)) now.push(w);
      // Finishing a turn on the old runner after a handover: told when it
      // comes across (THREADBEAR-5).
      else if (away?.(w.threadId)) kept.push({ ...w, due: build });
      else log.info('dropped an app restart watch for a thread that has gone', { threadId: w.threadId });
    }
    state.build = build;
    state.watching = kept;
    this.write(state);
    for (const w of now) this.tell(w, build);
  }

  // A thread a draining runner has handed over: if the app came back
  // while it was over there, it hears now.
  adopted(threadId: string): void {
    const state = this.read();
    const w = state.watching.find((x) => x.threadId === threadId && x.due);
    if (!w?.due) return;
    state.watching = state.watching.filter((x) => x !== w);
    this.write(state);
    this.tell(w, w.due);
  }

  private tell(w: Watch, build: AppBuild): void {
    const { runner, log, clock } = this.deps;
    try {
      const thread = runner.get(w.threadId);
      const age = clock.now() - Date.parse(w.requestedAt);
      const why = thread.archivedAt
        ? 'this thread is archived'
        : !(age < MAX_AGE_MS)
          ? 'the request is more than a day old'
          : undefined;
      let note = `Threadbear app restarted: ${w.fromShort ?? 'an earlier build'} to ${build.short}`;
      if (why) note += `\n\nNot carrying on by itself: ${why}.`;
      runner.note(w.threadId, note);
      if (why) return;
      const head = `The Threadbear app has restarted onto ${build.short} (${build.commit}), as you asked to hear.`;
      runner.send(w.threadId, w.text ? `${head}\n\n${w.text}` : `${head} Check your change in the running app.`, [], { origin: 'runner' });
      log.info('told a thread the app restarted', { threadId: w.threadId, build: build.short });
    } catch (e) {
      log.warn('could not tell a thread the app restarted', { threadId: w.threadId, error: String(e) });
    }
  }

  private read(): SavedState {
    try {
      const saved = JSON.parse(fs.readFileSync(appRestartsPath(this.deps.home), 'utf8')) as Partial<SavedState>;
      return { ...(saved.build ? { build: saved.build } : {}), watching: Array.isArray(saved.watching) ? saved.watching : [] };
    } catch {
      return { watching: [] };
    }
  }

  private write(state: SavedState): void {
    const file = appRestartsPath(this.deps.home);
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(state, null, 2));
    fs.renameSync(`${file}.tmp`, file);
  }
}
