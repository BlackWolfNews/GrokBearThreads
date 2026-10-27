// WebSocket JSON-RPC 2.0 server at ws://127.0.0.1:<port>/rpc.
import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import type { Runner, Notification } from './runner.ts';
import type { Logger } from './log.ts';
import { EFFORT_LEVELS, ErrorCode, RpcError, isEffortLevel } from './protocol.ts';
import type { ApprovalDecision, EffortLevel, ImageRef, PermissionMode } from './protocol.ts';

type Conn = {
  id: number;
  ws: WebSocket;
  authed: boolean;
  subs: Set<string>;
  client?: string;
  authTimer?: NodeJS.Timeout;
};

// A client that hasn't authenticated by then is dropped.
const AUTH_TIMEOUT_MS = 5000;
// Backpressure for a client that stops reading (a hung app, a debugger):
// past SKIP_DELTAS_BYTES of unsent data, transient deltas are skipped (the
// persisted event replaces them anyway); past CLOSE_BYTES the socket is
// closed with 4408, and the client reconnects and replays from its last seq.
const SKIP_DELTAS_BYTES = 1024 * 1024;
const CLOSE_BYTES = 32 * 1024 * 1024;
// How long close() waits for clients to finish closing before dropping them.
const CLOSE_GRACE_MS = 1000;

export type RpcServerOptions = {
  host: string;
  port: number;
  token: string;
  runner: Runner;
  log: Logger;
  // Methods served beside the runner's own (runner.status and
  // runner.restart, from restart.ts), and notices for a client that has
  // just said hello beside the runner's.
  methods?: Record<string, (params: Record<string, unknown>) => unknown>;
  helloNotices?: () => { level: 'info' | 'warning' | 'error'; message: string }[];
  // Tests shorten these.
  authTimeoutMs?: number;
  skipDeltasBytes?: number;
  closeBytes?: number;
  closeGraceMs?: number;
};

export class RpcServer {
  private opts: RpcServerOptions;
  private http: http.Server;
  private wss: WebSocketServer;
  private conns = new Set<Conn>();
  private nextId = 1;
  private unlisten: () => void;

  constructor(opts: RpcServerOptions) {
    this.opts = opts;
    this.http = http.createServer((req, res) => {
      // Unauthenticated health check for scripts; it says nothing else.
      if (req.url === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end('{"ok":true}');
        return;
      }
      res.writeHead(404);
      res.end();
    });
    this.wss = new WebSocketServer({ server: this.http, path: '/rpc', maxPayload: 64 * 1024 * 1024 });
    this.wss.on('connection', (ws, req) => this.onConnection(ws, req));
    // ws re-emits the HTTP server's errors (EADDRINUSE on listen); listen()
    // reports those, and without a listener here they'd crash the process.
    this.wss.on('error', (e) => opts.log.warn('websocket server error', { error: String(e) }));
    this.unlisten = opts.runner.onNotification((n) => this.broadcast(n));
  }

  listen(): Promise<{ port: number }> {
    return new Promise((resolve, reject) => {
      this.http.once('error', reject);
      this.http.listen(this.opts.port, this.opts.host, () => {
        this.http.off('error', reject);
        const addr = this.http.address();
        resolve({ port: typeof addr === 'object' && addr ? addr.port : this.opts.port });
      });
    });
  }

  async close(): Promise<void> {
    this.unlisten();
    for (const c of this.conns) {
      clearTimeout(c.authTimer);
      c.ws.close(1001, 'runner stopping');
    }
    // wss.close waits for every client to answer the close, and ws gives a
    // silent one (a suspended app, a script blocked on `launchctl kickstart
    // -k`, which waits for this very exit) 30 s. That's past launchd's
    // ExitTimeOut, which would SIGKILL the runner and leave its CLIs for the
    // next start to sweep, so cut stragglers off after a moment.
    const cutOff = setTimeout(() => {
      for (const ws of this.wss.clients) ws.terminate();
    }, this.opts.closeGraceMs ?? CLOSE_GRACE_MS);
    await new Promise<void>((r) => this.wss.close(() => r()));
    clearTimeout(cutOff);
    await new Promise<void>((r) => this.http.close(() => r()));
  }

  private tokenOk(candidate: unknown): boolean {
    if (typeof candidate !== 'string') return false;
    const a = Buffer.from(candidate);
    const b = Buffer.from(this.opts.token);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  private onConnection(ws: WebSocket, req: http.IncomingMessage): void {
    const header = req.headers.authorization ?? '';
    const m = /^Bearer\s+(.+)$/i.exec(header);
    const conn: Conn = { id: this.nextId++, ws, authed: Boolean(m && this.tokenOk(m[1].trim())), subs: new Set() };
    this.conns.add(conn);
    if (!conn.authed) {
      conn.authTimer = setTimeout(() => {
        if (!conn.authed) ws.close(4401, 'unauthorized');
      }, this.opts.authTimeoutMs ?? AUTH_TIMEOUT_MS);
      conn.authTimer.unref();
    }
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        // The protocol is text only; before auth, anything else is refused.
        if (!conn.authed) ws.close(4401, 'unauthorized');
        return;
      }
      this.onMessage(conn, data.toString());
    });
    const gone = () => {
      clearTimeout(conn.authTimer);
      this.conns.delete(conn);
    };
    ws.on('close', gone);
    ws.on('error', gone);
  }

  private send(conn: Conn, obj: unknown): void {
    if (conn.ws.readyState === WebSocket.OPEN) this.write(conn, JSON.stringify(obj), false);
  }

  private write(conn: Conn, msg: string, skippable: boolean): void {
    const buffered = conn.ws.bufferedAmount;
    if (buffered > (this.opts.closeBytes ?? CLOSE_BYTES)) {
      this.opts.log.warn('client is not reading; closing it', { conn: conn.id, client: conn.client, buffered });
      conn.ws.close(4408, 'too far behind');
      this.conns.delete(conn);
      return;
    }
    if (skippable && buffered > (this.opts.skipDeltasBytes ?? SKIP_DELTAS_BYTES)) return;
    conn.ws.send(msg);
  }

  private broadcast(n: Notification): void {
    const msg = JSON.stringify({ jsonrpc: '2.0', method: n.method, params: n.params });
    const transient = n.method === 'thread.event' && n.params.event.type.endsWith('.delta');
    for (const c of [...this.conns]) {
      if (!c.authed || c.ws.readyState !== WebSocket.OPEN) continue;
      if (n.method === 'thread.event' && !c.subs.has(n.params.threadId)) continue;
      this.write(c, msg, transient);
    }
  }

  private onMessage(conn: Conn, raw: string): void {
    let msg: { jsonrpc?: string; id?: string | number | null; method?: unknown; params?: unknown };
    try {
      msg = JSON.parse(raw);
    } catch {
      if (!conn.authed) return conn.ws.close(4401, 'unauthorized');
      return this.send(conn, { jsonrpc: '2.0', id: null, error: { code: ErrorCode.parseError, message: 'Parse error' } });
    }
    const id = msg?.id ?? null;
    if (!conn.authed) {
      // Clients that can't set headers authenticate with their first message.
      if (msg?.method === 'auth' && this.tokenOk((msg.params as { token?: unknown } | undefined)?.token)) {
        conn.authed = true;
        clearTimeout(conn.authTimer);
        if (id !== null) this.send(conn, { jsonrpc: '2.0', id, result: {} });
        return;
      }
      conn.ws.close(4401, 'unauthorized');
      return;
    }
    if (!msg || typeof msg !== 'object' || Array.isArray(msg) || typeof msg.method !== 'string') {
      return this.send(conn, { jsonrpc: '2.0', id, error: { code: ErrorCode.invalidRequest, message: 'Invalid request' } });
    }
    let result: unknown;
    try {
      result = this.dispatch(conn, msg.method, (msg.params ?? {}) as Record<string, unknown>);
    } catch (e) {
      if (id === null) return;
      if (e instanceof RpcError) {
        return this.send(conn, { jsonrpc: '2.0', id, error: { code: e.code, message: e.message, ...(e.data ? { data: e.data } : {}) } });
      }
      this.opts.log.error('request failed', { method: msg.method, error: String(e) });
      return this.send(conn, { jsonrpc: '2.0', id, error: { code: ErrorCode.other, message: (e as Error)?.message ?? String(e) } });
    }
    // A handler that has to wait (panels.render takes a screenshot) returns
    // a promise; everything else answers in this tick.
    if (result instanceof Promise) {
      result.then(
        (value) => {
          if (id !== null) this.send(conn, { jsonrpc: '2.0', id, result: value });
        },
        (e) => {
          if (id === null) return;
          if (e instanceof RpcError) {
            this.send(conn, { jsonrpc: '2.0', id, error: { code: e.code, message: e.message, ...(e.data ? { data: e.data } : {}) } });
          } else {
            this.opts.log.error('request failed', { method: msg.method, error: String(e) });
            this.send(conn, { jsonrpc: '2.0', id, error: { code: ErrorCode.other, message: (e as Error)?.message ?? String(e) } });
          }
        },
      );
      return;
    }
    if (id !== null) this.send(conn, { jsonrpc: '2.0', id, result });
    // Things the app should know about that happened before it connected
    // (a missing claude binary, CLIs stopped at startup).
    if (msg.method === 'hello') {
      for (const n of [...this.opts.runner.noticesForNewClient(), ...(this.opts.helloNotices?.() ?? [])]) {
        this.send(conn, { jsonrpc: '2.0', method: 'runner.notice', params: n });
      }
    }
  }

  // Every handler is synchronous, so a subscribe's replay and the start of
  // its live stream happen in the same tick and nothing can slip between.
  private dispatch(conn: Conn, method: string, p: Record<string, unknown>): unknown {
    const r = this.opts.runner;
    switch (method) {
      case 'auth':
        return {};
      case 'hello':
        conn.client = optString(p, 'client');
        return r.hello();
      case 'threads.list': {
        const include = p.include === undefined ? undefined : stringArray(p, 'include');
        for (const x of include ?? []) {
          if (x !== 'inbox' && x !== 'snoozed' && x !== 'archived') throw bad(`unknown include value ${x}`);
        }
        return { threads: r.list(include as ('inbox' | 'snoozed' | 'archived')[] | undefined) };
      }
      case 'threads.search':
        return { threads: r.search(reqString(p, 'query'), optInt(p, 'limit')) };
      case 'threads.create': {
        const res = r.create({
          text: optString(p, 'text') ?? '',
          images: optImages(p),
          cwd: optString(p, 'cwd'),
          accountId: optString(p, 'accountId'),
          model: optString(p, 'model'),
          effort: optEffort(p),
          permissionMode: optMode(p),
          title: optString(p, 'title'),
        });
        return { thread: res.thread, turnId: res.turnId };
      }
      case 'threads.send':
        return r.send(reqString(p, 'threadId'), optString(p, 'text') ?? '', optImages(p) ?? []);
      case 'threads.interrupt':
        return r.interrupt(reqString(p, 'threadId'));
      case 'threads.update': {
        const upd: Parameters<Runner['update']>[0] = { threadId: reqString(p, 'threadId') };
        if (p.title !== undefined) upd.title = reqString(p, 'title');
        if (p.cwd !== undefined) upd.cwd = reqString(p, 'cwd');
        if (p.accountId !== undefined) upd.accountId = reqString(p, 'accountId');
        if (p.model !== undefined) upd.model = p.model === null ? null : reqString(p, 'model');
        if (p.effort !== undefined) upd.effort = p.effort === null ? null : optEffort(p);
        if (p.permissionMode !== undefined) upd.permissionMode = optMode(p);
        if (p.snoozedUntil !== undefined) upd.snoozedUntil = p.snoozedUntil === null ? null : reqString(p, 'snoozedUntil');
        if (p.archived !== undefined) {
          if (typeof p.archived !== 'boolean') throw bad('archived must be a boolean');
          upd.archived = p.archived;
        }
        return r.update(upd);
      }
      case 'threads.delete':
        return r.delete(reqString(p, 'threadId'));
      case 'threads.events':
        return r.events(reqString(p, 'threadId'), {
          afterSeq: optInt(p, 'afterSeq'),
          beforeSeq: optInt(p, 'beforeSeq'),
          limit: optInt(p, 'limit'),
        });
      case 'threads.subagent':
        return r.subagent(reqString(p, 'threadId'), reqString(p, 'subagentId'));
      case 'threads.subscribe': {
        const threadId = reqString(p, 'threadId');
        const backlog = r.backlog(threadId, optInt(p, 'afterSeq') ?? 0);
        conn.subs.add(threadId);
        return backlog;
      }
      case 'threads.unsubscribe':
        conn.subs.delete(reqString(p, 'threadId'));
        return {};
      case 'threads.markSeen':
        return r.markSeen(reqString(p, 'threadId'), reqNumber(p, 'seq'));
      case 'approvals.respond': {
        const decision = reqString(p, 'decision') as ApprovalDecision;
        if (!['allow', 'allowAlways', 'deny', 'answered'].includes(decision)) throw bad('bad decision');
        let answers: Record<string, string> | undefined;
        if (p.answers !== undefined) {
          if (!p.answers || typeof p.answers !== 'object' || Array.isArray(p.answers)) throw bad('answers must be an object');
          answers = {};
          for (const [k, v] of Object.entries(p.answers)) {
            answers[k] = Array.isArray(v) ? v.map(String).join(', ') : String(v);
          }
        }
        return r.respondApproval({
          threadId: reqString(p, 'threadId'),
          approvalId: reqString(p, 'approvalId'),
          decision,
          message: optString(p, 'message'),
          answers,
        });
      }
      case 'media.import':
        return r.importMedia(reqString(p, 'path'));
      case 'panels.render':
        return r.renderPanel(reqString(p, 'threadId'), reqString(p, 'panelId'));
      case 'actions.run':
        return r.runAction(reqString(p, 'threadId'), reqString(p, 'actionId'));
      default: {
        // hasOwn, so "constructor" and friends aren't methods.
        const methods = this.opts.methods;
        if (methods && Object.hasOwn(methods, method)) return methods[method](p);
        throw new RpcError(ErrorCode.methodNotFound, `Unknown method ${method}`);
      }
    }
  }
}

function bad(message: string): RpcError {
  return new RpcError(ErrorCode.badParams, message);
}

function reqString(p: Record<string, unknown>, k: string): string {
  const v = p[k];
  if (typeof v !== 'string') throw bad(`${k} must be a string`);
  return v;
}

function optString(p: Record<string, unknown>, k: string): string | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw bad(`${k} must be a string`);
  return v;
}

function reqNumber(p: Record<string, unknown>, k: string): number {
  const v = p[k];
  if (typeof v !== 'number' || !Number.isFinite(v)) throw bad(`${k} must be a number`);
  return v;
}

function optNumber(p: Record<string, unknown>, k: string): number | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'number' || !Number.isFinite(v)) throw bad(`${k} must be a number`);
  return v;
}

// Seqs and limits index the event log, so they must be whole numbers.
function optInt(p: Record<string, unknown>, k: string): number | undefined {
  const v = optNumber(p, k);
  if (v !== undefined && !Number.isInteger(v)) throw bad(`${k} must be a whole number`);
  return v;
}

function stringArray(p: Record<string, unknown>, k: string): string[] {
  const v = p[k];
  if (!Array.isArray(v) || v.some((x) => typeof x !== 'string')) throw bad(`${k} must be an array of strings`);
  return v as string[];
}

function optMode(p: Record<string, unknown>): PermissionMode | undefined {
  const v = p.permissionMode;
  if (v === undefined || v === null) return undefined;
  if (v !== 'full' && v !== 'ask') throw bad('permissionMode must be "full" or "ask"');
  return v;
}

function optEffort(p: Record<string, unknown>): EffortLevel | undefined {
  const v = p.effort;
  if (v === undefined || v === null) return undefined;
  if (!isEffortLevel(v)) throw bad(`effort must be one of ${EFFORT_LEVELS.join(', ')}`);
  return v;
}

function optImages(p: Record<string, unknown>): ImageRef[] | undefined {
  const v = p.images;
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v)) throw bad('images must be an array');
  return v.map((x) => {
    if (!x || typeof x !== 'object' || typeof (x as ImageRef).path !== 'string') throw bad('each image needs a path');
    return x as ImageRef;
  });
}
