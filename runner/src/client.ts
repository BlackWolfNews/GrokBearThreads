// Small JSON-RPC client for the runner, used by the tb CLI and the tests.
import { WebSocket } from 'ws';

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

export class RpcClientError extends Error {
  code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

export class RunnerClient {
  private ws: WebSocket;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private handlers = new Set<(method: string, params: any) => void>();
  readonly opened: Promise<void>;
  closeInfo?: { code: number; reason: string };

  constructor(url: string, token?: string, opts: { headerAuth?: boolean } = {}) {
    const headers = token && opts.headerAuth !== false ? { Authorization: `Bearer ${token}` } : undefined;
    this.ws = new WebSocket(url, { headers });
    this.opened = new Promise((resolve, reject) => {
      this.ws.once('open', () => resolve());
      this.ws.once('error', reject);
    });
    this.ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id !== undefined && msg.id !== null && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new RpcClientError(msg.error.code, msg.error.message));
        else p.resolve(msg.result);
      } else if (msg.method) {
        for (const h of this.handlers) h(msg.method, msg.params);
      }
    });
    this.ws.on('close', (code, reason) => {
      this.closeInfo = { code, reason: reason.toString() };
      for (const p of this.pending.values()) p.reject(new Error(`connection closed (${code})`));
      this.pending.clear();
    });
  }

  static async connect(url: string, token: string): Promise<RunnerClient> {
    const c = new RunnerClient(url, token);
    await c.opened;
    return c;
  }

  onNotification(fn: (method: string, params: any) => void): () => void {
    this.handlers.add(fn);
    return () => this.handlers.delete(fn);
  }

  call<T = any>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      // A call on a closed socket would otherwise wait forever.
      if (this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error(`connection not open (${this.closeInfo ? `closed ${this.closeInfo.code}` : 'state ' + this.ws.readyState})`));
        return;
      }
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }

  sendRaw(obj: unknown): void {
    this.ws.send(JSON.stringify(obj));
  }

  waitClosed(): Promise<{ code: number; reason: string }> {
    if (this.closeInfo) return Promise.resolve(this.closeInfo);
    return new Promise((resolve) => this.ws.once('close', (code, reason) => resolve({ code, reason: reason.toString() })));
  }

  close(): void {
    this.ws.close();
  }
}
