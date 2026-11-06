// Tool approvals and questions waiting on the user, and their answers.
// Part of the Runner (runner.ts), split out on 4 Nov 2026 as a plain move so a
// fork's change to one area doesn't clash with another's. Each method's `this`
// is the Runner; runner.ts puts them on its prototype.
import type { Runner } from '../runner.ts';
import type { RunnerPart } from './part.ts';
import type { ApprovalDecision, EventBody, PermissionMode } from '../protocol.ts';
import { ErrorCode, RpcError } from '../protocol.ts';
import type { QuestionAnswer, QuestionRequest, ToolApprovalAnswer, ToolApprovalRequest } from '../adapters/types.ts';
import { approvalTitle, type AgentApprovalRequest } from '../threadbear-mcp.ts';
import crypto from 'node:crypto';
import type { PendingApproval, ThreadState } from '../runner.ts';
import { matchAnswers } from '../runner.ts';
import { SECRET_TIMEOUT_DEFAULT_MIN, SECRET_TIMEOUT_MAX_MIN, type SecretFiles } from '../secrets.ts';
import { START_CARD, type RequestAnswer } from '../cross-runner.ts';

export type SecretRequest = { label: string; reason: string; placeholder?: string; timeoutMinutes?: number; toolUseId?: string; signal?: AbortSignal };
export type SecretAnswer = ({ status: 'saved' } & SecretFiles) | { status: 'declined' | 'expired'; message?: string };

// Closes a pending card of any kind without an answer: Mike wrote instead,
// the turn ended, the thread went.
export function settleDeclined(p: PendingApproval, decision: 'deny' | 'expired', message?: string): void {
  if (p.kind === 'tool') p.resolve({ decision, message });
  else if (p.kind === 'question') p.resolve({ answers: null, message });
  else if (p.kind === 'request') p.resolve({ status: decision === 'deny' ? 'declined' : 'expired', ...(message ? { message } : {}) });
  else p.resolve({ status: decision === 'deny' ? 'declined' : 'expired', message });
}

// What Go ahead says to an agent whose plan isn't waiting on a call.
export const PLAN_GO_AHEAD = 'Go ahead with the plan.';

export const approvalsPart = {
  respondApproval(this: Runner, params: {
    threadId: string;
    approvalId: string;
    decision: ApprovalDecision;
    message?: string;
    answers?: Record<string, string>;
  }): Record<string, never> {
    const st = this.mustGet(params.threadId);
    const pending = st.rt.approvals.get(params.approvalId);
    if (!pending) throw new RpcError(ErrorCode.badParams, 'That approval is no longer pending.');
    if (pending.kind === 'secret') {
      // A phone from before secrets draws any card it doesn't know as
      // Allow/Deny: Deny declines, and Allow can't carry a value.
      if (params.decision === 'deny') return this.answerSecret({ threadId: params.threadId, approvalId: params.approvalId, decline: true });
      throw new RpcError(ErrorCode.badParams, 'A secret is answered with secrets.answer: update the Threadbear app, or answer it on the Mac.');
    }
    if (pending.kind === 'request') {
      if (params.decision === 'deny') {
        this.resolveApproval(st, pending.approvalId, 'deny', params.message);
        pending.resolve({ status: 'declined', ...(params.message ? { message: params.message } : {}) });
        return {};
      }
      // Allowed only once the backend says it was started (cross-runner.ts):
      // the main Mac's runner marks it before it answers.
      return pending.check().then((a) => {
        if (st.rt.approvals.get(pending.approvalId) !== pending) return {};
        this.resolveApproval(st, pending.approvalId, a.status === 'started' ? 'allow' : 'deny', a.status === 'started' ? `Started on ${a.runnerName}` : undefined);
        pending.resolve(a);
        return {};
      }) as unknown as Record<string, never>;
    }
    if (pending.kind === 'question') {
      if (params.decision === 'answered') {
        const answers = matchAnswers(pending.questions, params.answers ?? {});
        if (!answers) throw new RpcError(ErrorCode.badParams, 'answers must cover every question');
        this.resolveApproval(st, pending.approvalId, 'answered', params.message);
        pending.resolve({ answers });
      } else if (params.decision === 'deny') {
        this.resolveApproval(st, pending.approvalId, 'deny', params.message);
        pending.resolve({ answers: null, message: params.message });
      } else {
        throw new RpcError(ErrorCode.badParams, 'A question takes "answered" or "deny".');
      }
    } else {
      if (params.decision !== 'allow' && params.decision !== 'allowAlways' && params.decision !== 'deny') {
        throw new RpcError(ErrorCode.badParams, 'An approval takes "allow", "allowAlways" or "deny".');
      }
      this.resolveApproval(st, pending.approvalId, params.decision, params.message);
      // An approved plan goes ahead in the mode resolveApproval just left plan mode for.
      const mode = pending.plan && params.decision !== 'deny' ? st.rec.permissionMode : undefined;
      pending.resolve({ decision: params.decision, message: params.message, ...(mode ? { mode } : {}) });
    }
    return {};
  },

  // plans.approve (docs/protocol.md, "Plan first"): Go ahead on a plan card.
  // Claude's plan is an ExitPlanMode call waiting on its approval, which
  // this allows. Otherwise (Codex, whose plan ends its turn, or Claude's
  // after a restart dropped the call) the thread leaves plan mode and Mike
  // tells it to go ahead.
  approvePlan(this: Runner, params: { threadId: string; itemId: string }): Record<string, never> {
    const st = this.mustGet(params.threadId);
    const { rec, rt } = st;
    if (!rec.openPlan || rec.openPlan !== params.itemId) throw new RpcError(ErrorCode.badParams, 'That plan is no longer waiting.');
    const call = [...rt.approvals.values()].find((p) => p.kind === 'tool' && p.plan === params.itemId);
    if (call) return this.respondApproval({ threadId: params.threadId, approvalId: call.approvalId, decision: 'allow' });
    const mode = this.leavePlan(st);
    rt.session?.setPermissionMode(mode).catch(() => {
      rt.releaseWhenIdle = true;
    });
    this.send(params.threadId, PLAN_GO_AHEAD);
    return {};
  },

  // Approving the plan: back to the mode the thread had before plan mode.
  // Returns that mode; the caller tells the CLI.
  leavePlan(this: Runner, st: ThreadState): PermissionMode {
    const { rec, rt } = st;
    const mode = rec.modeBeforePlan && rec.modeBeforePlan !== 'plan' ? rec.modeBeforePlan : 'full';
    if (rec.openPlan) this.emit(st, { type: 'plan.resolved', itemId: rec.openPlan, decision: 'go' }, rt.turn?.turnId);
    delete rec.openPlan;
    delete rec.modeBeforePlan;
    if (rec.permissionMode === 'plan') rec.permissionMode = mode;
    this.markDirty(st);
    return rec.permissionMode;
  },

  // A request can come with no turn running: a background subagent keeps
  // working after the turn that started it ended. It gets a turn of its own
  // so the card is shown rather than the subagent being stopped.
  turnForRequest(this: Runner, st: ThreadState, gen: number): boolean {
    const { rt } = st;
    if (rt.generation !== gen || rt.closing || this.stopping) return false;
    if (!rt.turn) this.openCliTurn(st);
    return true;
  },

  requestApproval(this: Runner, st: ThreadState, gen: number, req: ToolApprovalRequest): Promise<ToolApprovalAnswer> {
    if (!this.turnForRequest(st, gen)) return Promise.resolve({ decision: 'expired' });
    const approvalId = crypto.randomUUID();
    const body: EventBody = {
      type: 'approval.requested',
      approvalId,
      name: req.name,
      title: approvalTitle(req.name, req.input, (q) => this.findThread(q)) ?? req.title,
      input: req.input,
      options: req.canAlwaysAllow ? ['allow', 'allowAlways', 'deny'] : ['allow', 'deny'],
    };
    if (req.toolUseId) body.itemId = req.toolUseId;
    const plan = req.name === 'ExitPlanMode' && req.toolUseId && req.toolUseId === st.rec.openPlan ? req.toolUseId : undefined;
    return new Promise((resolve) => {
      // A card offered without "Always allow" never answers with it, even
      // if a client sends it: it would save a rule Mike was never offered.
      const answer = req.canAlwaysAllow ? resolve : (a: ToolApprovalAnswer) => resolve(a.decision === 'allowAlways' ? { ...a, decision: 'allow' } : a);
      this.addApproval(st, { approvalId, kind: 'tool', main: Boolean(req.toolUseId), ...(plan ? { plan } : {}), resolve: answer }, body, req.signal);
    });
  },

  // A threadbear tool's own card, for a call that would raise access from a
  // thread not in full mode (threadbear-mcp.ts, "Raising access"). Never
  // "Always allow". The agent's CLI waits on the call, so a message from
  // Mike declines it, as with a question.
  requestAgentApproval(this: Runner, threadId: string, req: AgentApprovalRequest): Promise<ToolApprovalAnswer> {
    const st = this.mustGet(threadId);
    if (!this.turnForRequest(st, st.rt.generation)) return Promise.resolve({ decision: 'expired', message: 'The thread is not running a turn.' });
    const approvalId = crypto.randomUUID();
    const body: EventBody = { type: 'approval.requested', approvalId, name: req.name, title: req.title, input: req.input, options: ['allow', 'deny'] };
    return new Promise((resolve) => {
      const answer = (a: ToolApprovalAnswer) => resolve(a.decision === 'allowAlways' ? { ...a, decision: 'allow' } : a);
      this.addApproval(st, { approvalId, kind: 'tool', main: true, resolve: answer }, body, req.signal ?? new AbortController().signal);
    });
  },

  requestQuestion(this: Runner, st: ThreadState, gen: number, req: QuestionRequest): Promise<QuestionAnswer> {
    if (!this.turnForRequest(st, gen)) return Promise.resolve({ answers: null });
    const approvalId = crypto.randomUUID();
    const body: EventBody = { type: 'question.requested', approvalId, questions: req.questions };
    if (req.toolUseId) body.itemId = req.toolUseId;
    return new Promise((resolve) => {
      this.addApproval(st, { approvalId, kind: 'question', main: Boolean(req.toolUseId), questions: req.questions, resolve }, body, req.signal);
    });
  },

  // ask_secret (docs/protocol.md, "Secrets"): a card that waits for Mike to
  // type a secret on the Mac or the phone. Resolves with the file's paths,
  // or declined or expired; never with the value.
  requestSecret(this: Runner, threadId: string, req: SecretRequest): Promise<SecretAnswer> {
    const st = this.mustGet(threadId);
    if (!this.turnForRequest(st, st.rt.generation)) return Promise.resolve({ status: 'expired', message: 'The thread is not running a turn.' });
    const approvalId = crypto.randomUUID();
    const body: EventBody = { type: 'secret.requested', approvalId, label: req.label, reason: req.reason };
    if (req.placeholder) body.placeholder = req.placeholder;
    if (req.toolUseId) body.itemId = req.toolUseId;
    const minutes = Math.min(Math.max(req.timeoutMinutes ?? SECRET_TIMEOUT_DEFAULT_MIN, 1), SECRET_TIMEOUT_MAX_MIN);
    return new Promise((resolve) => {
      const timer = this.clock.setTimeout(() => this.expireApproval(st, approvalId, 'No answer in time.'), minutes * 60_000);
      const done = (a: SecretAnswer) => {
        timer.cancel();
        resolve(a);
      };
      // The agent's own call: a message from Mike declines it, as with a question.
      this.addApproval(st, { approvalId, kind: 'secret', main: true, resolve: done }, body, req.signal ?? new AbortController().signal);
    });
  },

  // create_thread asking another runner (cross-runner.ts): a card that waits
  // for the main Mac to start the thread, or for Mike to say no.
  requestCard(this: Runner, threadId: string, c: { approvalId: string; title: string; input: Record<string, unknown>; minutes: number; check: () => Promise<RequestAnswer> }): Promise<RequestAnswer> {
    const st = this.mustGet(threadId);
    if (!this.turnForRequest(st, st.rt.generation)) return Promise.resolve({ status: 'expired', message: 'The thread is not running a turn.' });
    const body: EventBody = { type: 'approval.requested', approvalId: c.approvalId, name: START_CARD, title: c.title, input: c.input, options: ['allow', 'deny'] };
    return new Promise((resolve) => {
      const timer = this.clock.setTimeout(() => this.expireApproval(st, c.approvalId, 'No answer in time.'), c.minutes * 60_000);
      const done = (a: RequestAnswer) => {
        timer.cancel();
        resolve(a);
      };
      this.addApproval(st, { approvalId: c.approvalId, kind: 'request', main: true, check: c.check, resolve: done }, body, new AbortController().signal);
    });
  },

  // secrets.answer: Mike typed it (or declined) on a Mac, or the phone's
  // sealed answer was opened (sync.ts). The file is written before the card
  // closes, so a failed write leaves it open with the error.
  answerSecret(this: Runner, params: { threadId: string; approvalId: string; secret?: string; decline?: boolean }): Record<string, never> {
    const st = this.mustGet(params.threadId);
    const pending = st.rt.approvals.get(params.approvalId);
    if (!pending) throw new RpcError(ErrorCode.badParams, 'That request is no longer waiting.');
    if (pending.kind !== 'secret') throw new RpcError(ErrorCode.badParams, 'That card is not asking for a secret.');
    if (params.decline) {
      this.resolveApproval(st, pending.approvalId, 'deny');
      pending.resolve({ status: 'declined' });
      return {};
    }
    const value = typeof params.secret === 'string' ? params.secret.trim() : '';
    if (!value) throw new RpcError(ErrorCode.badParams, 'Type the secret, or decline.');
    let files: SecretFiles;
    try {
      files = this.secrets.write(value);
    } catch (e) {
      // The error's code only: an fs message can't hold the value, but say
      // as little as possible anyway.
      throw new RpcError(ErrorCode.other, `Couldn't save it (${(e as NodeJS.ErrnoException).code ?? 'error'}).`);
    }
    this.resolveApproval(st, pending.approvalId, 'answered');
    pending.resolve({ status: 'saved', ...files });
    return {};
  },

  addApproval(this: Runner, st: ThreadState, pending: PendingApproval, body: EventBody, signal: AbortSignal): void {
    const { rec, rt } = st;
    rt.approvals.set(pending.approvalId, pending);
    rec.pendingApprovals.push(pending.approvalId);
    this.emit(st, body, rt.turn?.turnId);
    rec.status = 'waiting';
    this.markDirty(st);
    signal.addEventListener('abort', () => this.expireApproval(st, pending.approvalId, 'Cancelled.'), { once: true });
  },

  resolveApproval(this: Runner, st: ThreadState, approvalId: string, decision: ApprovalDecision, message?: string): void {
    const { rec, rt } = st;
    const pending = rt.approvals.get(approvalId);
    rt.approvals.delete(approvalId);
    rec.pendingApprovals = rec.pendingApprovals.filter((x) => x !== approvalId);
    const body: EventBody = { type: 'approval.resolved', approvalId, decision };
    if (message) body.message = message;
    this.emit(st, body, rt.turn?.turnId);
    // A plan's approval, however it was answered (the card, Return in the
    // composer, the phone): allowed, it goes ahead; declined, it goes back
    // for another go. Expired (a restart, Stop) leaves the plan waiting, and
    // Go ahead then sends it on in words.
    if (pending?.kind === 'tool' && pending.plan && pending.plan === rec.openPlan) {
      if (decision === 'allow' || decision === 'allowAlways') this.leavePlan(st);
      else if (decision === 'deny') {
        this.emit(st, { type: 'plan.resolved', itemId: pending.plan, decision: 'revise' }, rt.turn?.turnId);
        delete rec.openPlan;
      }
    }
    if (rec.status === 'waiting' && rt.approvals.size === 0) rec.status = rt.turn ? 'running' : 'idle';
    this.markDirty(st);
  },

  expireApproval(this: Runner, st: ThreadState, approvalId: string, message: string): void {
    const pending = st.rt.approvals.get(approvalId);
    if (!pending) return;
    this.resolveApproval(st, approvalId, 'expired', message);
    settleDeclined(pending, 'expired', message);
  },

  expireApprovals(this: Runner, st: ThreadState, message: string): void {
    for (const id of [...st.rt.approvals.keys()]) this.expireApproval(st, id, message);
  },
};

export type ApprovalsPart = RunnerPart<typeof approvalsPart>;
