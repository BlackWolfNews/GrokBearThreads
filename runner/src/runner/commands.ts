// Slash commands from the message box (docs/protocol.md, "Slash commands"):
// the ones the runner does itself, and the picker's list.
// Each method's `this` is the Runner; runner.ts puts them on its prototype.
import crypto from 'node:crypto';
import type { Runner, ThreadState } from '../runner.ts';
import { effortTitle, modelRow } from '../runner.ts';
import type { RunnerPart } from './part.ts';
import type { Account, EffortLevel } from '../protocol.ts';
import { isEffortLevel } from '../protocol.ts';
import type { QueuedSend } from '../store.ts';
import { commandList, parseCommand, planCommand, type CommandPlan, type SlashCommand } from '../slash-commands.ts';

// A folder's command list (its skills, its .claude/commands) changes
// rarely, and asking a CLI for it takes a second or two.
const LIST_TTL_MS = 10 * 60_000;

export const commandsPart = {
  // The plan for a message, or undefined when it's words for the agent.
  commandPlan(this: Runner, st: ThreadState, text: string): CommandPlan | undefined {
    const cmd = parseCommand(text);
    return cmd ? planCommand(st.rec.provider, cmd) : undefined;
  },

  // Runs a command the runner answers itself, as the turn the message
  // started, and ends that turn. False for one the CLI is to run.
  runLocalCommand(this: Runner, st: ThreadState, msg: QueuedSend): boolean {
    const plan = this.commandPlan(st, msg.text);
    if (!plan || plan.kind === 'cli') return false;
    const { rec, rt } = st;
    const turn = rt.turn!;
    // Settings changed here apply to the next turn, which is the one
    // that matters; this turn is the command's and is already over.
    turn.local = true;
    const say = (text: string) => this.emit(st, { type: 'system.note', text }, turn.turnId);
    const account = this.accounts.get(rec.accountId);
    try {
      switch (plan.kind) {
        case 'note':
          say(plan.text);
          break;
        case 'model': {
          const choices = (account?.models ?? []).map((m) => m.title || m.id);
          const now = this.modelLabel(rec);
          if (!plan.args) {
            say(`This thread is on ${now}.${choices.length ? ` Type /model and one of: ${choices.join(', ')}.` : ''}`);
            break;
          }
          const model = account ? pickModel(account, plan.args) : undefined;
          if (!model) {
            say(`There's no model called "${plan.args}" on ${account?.title ?? 'this login'}.${choices.length ? ` Pick one of: ${choices.join(', ')}.` : ''}`);
            break;
          }
          this.update({ threadId: rec.id, model });
          say(`This thread is on ${this.modelLabel(rec)} from here.`);
          break;
        }
        case 'effort': {
          const levels = (account && modelRow(account, rec.model ?? account.defaultModel)?.effortLevels) ?? [];
          const arg = plan.args.toLowerCase().replace(/\s+/g, '');
          if (!arg) {
            say(`${rec.effort ? `${effortTitle(rec.effort)} effort` : "The model's own effort level"}.${levels.length ? ` Type /effort and one of: ${levels.join(', ')}, or default.` : ''}`);
            break;
          }
          const effort: EffortLevel | null | undefined = arg === 'default' || arg === 'auto' ? null : isEffortLevel(arg) ? arg : arg === 'extrahigh' ? 'xhigh' : undefined;
          if (effort === undefined) {
            say(`"${plan.args}" isn't an effort level.${levels.length ? ` Pick one of: ${levels.join(', ')}, or default.` : ''}`);
            break;
          }
          this.update({ threadId: rec.id, effort });
          say(rec.effort ? `Effort set to ${effortTitle(rec.effort)}.` : "Back to the model's own effort level.");
          break;
        }
        case 'clear':
          // A fresh native session from the next message; the CLI that has
          // the old one goes once this turn is over.
          if (rt.session) rt.releaseWhenIdle = true;
          rec.nativeSessionId = crypto.randomUUID();
          rec.sessionUsed = false;
          rec.sessionCostTotal = 0;
          delete rec.resumeAt;
          delete rec.contextTokens;
          // The new session hears about the thread's projects again.
          delete rec.projectsTold;
          say('Cleared the conversation. The agent starts fresh from your next message; the transcript above stays here for you.');
          break;
        case 'status':
          say(statusText(this, st, account));
          break;
      }
    } catch (e) {
      this.emit(st, { type: 'error', message: e instanceof Error ? e.message : String(e) }, turn.turnId);
    }
    this.markDirty(st);
    this.completeTurn(st, { outcome: 'completed', durationMs: 0 });
    return true;
  },

  // The picker's list for a thread (threads.commands): Threadbear's own,
  // then the CLI's for the thread's folder, skills included.
  async threadCommands(this: Runner, threadId: string): Promise<{ commands: SlashCommand[] }> {
    const st = this.mustGet(threadId);
    const { rec, rt } = st;
    const account = this.accounts.get(rec.accountId);
    let cli: SlashCommand[] = [];
    const key = `${rec.accountId}\0${rec.cwd}`;
    const cached = this.commandCache.get(key);
    if (cached && this.clock.now() - cached.at < LIST_TTL_MS) cli = cached.commands;
    else {
      try {
        const live = rt.session?.commands ? await rt.session.commands() : undefined;
        const adapter = this.adapters[rec.provider];
        cli = live ?? (account && adapter?.commands ? await adapter.commands(account, rec.cwd) : []);
        this.commandCache.set(key, { at: this.clock.now(), commands: cli });
      } catch (e) {
        this.log.warn('could not list commands', { threadId, error: String(e) });
      }
    }
    return { commands: commandList(rec.provider, cli) };
  },
};

export type CommandsPart = RunnerPart<typeof commandsPart>;

// The model a /model argument names: a picker id, a full id or a title
// ("opus", "claude-opus-5-5", "Opus 5.5"), or for Claude any of its own
// aliases, which the CLI resolves.
export function pickModel(account: Account, arg: string): string | undefined {
  const want = arg.trim().toLowerCase();
  const squash = (s: string) => s.toLowerCase().replace(/[\s._-]+/g, '');
  const rows = account.models ?? [];
  const row =
    rows.find((m) => m.id.toLowerCase() === want || m.model.toLowerCase() === want) ??
    rows.find((m) => squash(m.title) === squash(want)) ??
    rows.find((m) => squash(m.title).startsWith(squash(want)) || squash(m.id).startsWith(squash(want)));
  if (row) return row.id;
  if (account.provider === 'claude' && /^(claude-[\w.-]+|opus|sonnet|haiku|fable|default|opusplan)(\[1m\])?$/i.test(want)) return want;
  return undefined;
}

// Codex's /status, from what the runner knows of the thread and its login.
function statusText(r: Runner, st: ThreadState, account: Account | undefined): string {
  const { rec } = st;
  const lines = [`${r.modelLabel(rec)}, ${rec.effort ? `${effortTitle(rec.effort)} effort` : "the model's own effort level"}, on ${account?.title ?? rec.accountId}.`];
  if (rec.contextTokens !== undefined) {
    const k = (n: number) => `${Math.round(n / 1000)}k`;
    lines.push(rec.contextWindow ? `Context: ${k(rec.contextTokens)} of ${k(rec.contextWindow)} tokens (${Math.round((rec.contextTokens / rec.contextWindow) * 100)}%).` : `Context: ${k(rec.contextTokens)} tokens.`);
  }
  const usage = r.safeAccounts().find((a) => a.id === rec.accountId)?.usage;
  for (const w of usage?.windows ?? []) lines.push(`${w.title}: ${Math.round(w.remainingPercent)}% left${w.resetsAt ? `, resets ${new Date(w.resetsAt).toLocaleString()}` : ''}.`);
  return lines.join('\n');
}

