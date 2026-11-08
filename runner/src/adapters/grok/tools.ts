// Threadbear's tools for one Grok thread. Grok can't take Claude's
// in-process MCP server, so it spawns mcp-bridge.mjs and this listens on
// the socket that bridge calls. The handlers are the same ones
// buildThreadbearTools builds. end_turn reads the thread's event log to
// see its own call (threadbear-mcp.ts, replied), so the call is recorded
// before the handler runs.
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import type { PermissionMode } from '../../protocol.ts';
import { ALWAYS_ASK_TOOLS, NEVER_ASK_TOOLS, SERVER_NAME } from '../../threadbear-mcp.ts';
import { toolTitle, truncateInput } from '../../tools.ts';
import type { ToolApprovalAnswer, ToolApprovalRequest } from '../types.ts';

// What buildThreadbearTools returns, loosely typed so every tool's
// argument shape fits one list. Same idea as Codex's ToolDefinition.
export type GrokTool = {
  name: string;
  description: string;
  inputSchema: object;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  handler: (args: any, extra: unknown) => Promise<{ content?: unknown[]; isError?: boolean }>;
  annotations?: { readOnlyHint?: boolean };
};

export type GrokToolHost = {
  requestApproval(req: ToolApprovalRequest): Promise<ToolApprovalAnswer>;
  cwd(): string;
  mode(): PermissionMode;
  rules(): Iterable<string>;
  addRules(rules: string[]): void;
  // Record the call on the thread before the handler runs.
  onCall(name: string, args: Record<string, unknown>): { itemId: string };
  onResult(itemId: string, ok: boolean, text: string): void;
};

type ListedTool = { name: string; description: string; inputSchema: unknown };

export function grokBridgePath(): string {
  return fileURLToPath(new URL('./mcp-bridge.mjs', import.meta.url));
}

// ACP stdio server entry: command, args, and env as {name, value} pairs.
export function grokMcpServer(socketPath: string): { name: string; command: string; args: string[]; env: [] } {
  return {
    name: SERVER_NAME,
    command: process.execPath,
    args: [grokBridgePath(), socketPath],
    env: [],
  };
}

// Most tools carry a zod raw shape. Claude's end_turn carries a whole zod
// object (context-budget.test.ts). Both become one schema.
function zodObject(schema: object): z.ZodType {
  const shape = schema as { _zod?: unknown };
  if (shape._zod) return schema as z.ZodType;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return z.object(schema as any);
}

export function toolSchemas(tools: GrokTool[]): ListedTool[] {
  return tools.map((t) => {
    const inputSchema = z.toJSONSchema(zodObject(t.inputSchema)) as Record<string, unknown>;
    delete inputSchema.$schema;
    return { name: t.name, description: t.description, inputSchema };
  });
}

function textOf(content: unknown[] | undefined): string {
  return (content ?? [])
    .map((c) => (c && typeof c === 'object' && (c as { type?: string }).type === 'text' ? String((c as { text?: unknown }).text ?? '') : ''))
    .filter(Boolean)
    .join('\n');
}

function reply(text: string, isError = false): { content: { type: 'text'; text: string }[]; isError?: boolean } {
  return isError ? { content: [{ type: 'text', text }], isError: true } : { content: [{ type: 'text', text }] };
}

async function runCall(tool: GrokTool, raw: Record<string, unknown>, host: GrokToolHost, signal: AbortSignal): Promise<{ content: { type: 'text'; text: string }[]; isError?: boolean }> {
  const parsed = zodObject(tool.inputSchema).safeParse(raw);
  if (!parsed.success) return reply(`Those arguments don't fit ${tool.name}: ${z.prettifyError(parsed.error)}`, true);
  const args = parsed.data as Record<string, unknown>;
  const fullName = `mcp__${SERVER_NAME}__${tool.name}`;
  const alwaysAsk = ALWAYS_ASK_TOOLS.has(fullName);
  const readOnly = NEVER_ASK_TOOLS.has(fullName) || tool.annotations?.readOnlyHint === true;
  const allowed = !alwaysAsk && [...host.rules()].includes(fullName);
  if (alwaysAsk || (host.mode() !== 'full' && !readOnly && !allowed)) {
    const ans = await host.requestApproval({
      name: fullName,
      title: toolTitle(fullName, args, host.cwd()),
      input: truncateInput(args),
      canAlwaysAllow: !alwaysAsk,
      signal,
    });
    if (signal.aborted) return reply('The tool call was cancelled.', true);
    if (ans.decision !== 'allow' && ans.decision !== 'allowAlways') {
      return reply(ans.message || (ans.decision === 'expired' ? 'The request expired before the user answered.' : 'The user denied this. Ask them how to proceed.'), true);
    }
    if (ans.decision === 'allowAlways' && !alwaysAsk) host.addRules([fullName]);
  }
  const opened = host.onCall(tool.name, args);
  try {
    const result = await tool.handler(args, { signal });
    const text = textOf(result.content);
    host.onResult(opened.itemId, !result.isError, text);
    return reply(text, Boolean(result.isError));
  } catch (e) {
    const text = (e as Error)?.message ?? String(e);
    host.onResult(opened.itemId, false, text);
    return reply(text, true);
  }
}

type BridgeMsg = {
  id?: number;
  method?: string;
  params?: { name?: string; arguments?: unknown };
};

// One unix socket per live Grok thread. Grok's bridge is the only client.
export class GrokToolServer {
  readonly socketPath: string;
  private server: net.Server;
  private sockets = new Set<net.Socket>();
  private tools: GrokTool[];
  private instructions: string;
  private host: GrokToolHost;
  private closed = false;

  constructor(tools: GrokTool[], instructions: string, host: GrokToolHost) {
    this.tools = tools;
    this.instructions = instructions;
    this.host = host;
    this.socketPath = path.join(os.tmpdir(), `tb-grok-${crypto.randomBytes(8).toString('hex')}.sock`);
    this.server = net.createServer((sock) => this.onConnection(sock));
  }

  names(): Set<string> {
    return new Set(this.tools.map((t) => t.name));
  }

  listen(): Promise<void> {
    return new Promise((resolve, reject) => {
      const onError = (e: Error) => {
        this.server.off('error', onError);
        reject(e);
      };
      this.server.once('error', onError);
      this.server.listen(this.socketPath, () => {
        this.server.off('error', onError);
        this.server.on('error', () => {});
        try {
          fs.chmodSync(this.socketPath, 0o600);
        } catch {
          // The path is unguessable either way. A failure to tighten it
          // still leaves the server on a sticky /tmp.
        }
        resolve();
      });
    });
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const sock of this.sockets) sock.destroy();
    this.server.close();
    try {
      fs.unlinkSync(this.socketPath);
    } catch {
      // Already gone.
    }
  }

  private onConnection(sock: net.Socket): void {
    this.sockets.add(sock);
    sock.on('close', () => this.sockets.delete(sock));
    sock.on('error', () => {});
    const rl = readline.createInterface({ input: sock });
    const write = (msg: unknown) => {
      if (!sock.destroyed) sock.write(`${JSON.stringify(msg)}\n`);
    };
    rl.on('line', (line) => {
      void this.onMessage(line, write, sock);
    });
  }

  private async onMessage(line: string, write: (msg: unknown) => void, sock: net.Socket): Promise<void> {
    let msg: BridgeMsg;
    try {
      msg = JSON.parse(line) as BridgeMsg;
    } catch {
      return;
    }
    if (msg.id === undefined) return;
    try {
      if (msg.method === 'hello') {
        write({ id: msg.id, result: { instructions: this.instructions, tools: toolSchemas(this.tools) } });
        return;
      }
      if (msg.method === 'call') {
        const name = typeof msg.params?.name === 'string' ? msg.params.name : '';
        const tool = this.tools.find((t) => t.name === name);
        if (!tool) {
          const known = this.tools.map((t) => t.name).join(', ');
          write({ id: msg.id, result: reply(`Threadbear has no tool called ${name || '(unnamed)'}. This thread's tools are: ${known || 'none'}.`, true) });
          return;
        }
        const raw = msg.params?.arguments && typeof msg.params.arguments === 'object' && !Array.isArray(msg.params.arguments) ? (msg.params.arguments as Record<string, unknown>) : {};
        const ac = new AbortController();
        const onClose = () => ac.abort();
        sock.once('close', onClose);
        const result = await runCall(tool, raw, this.host, ac.signal);
        sock.off('close', onClose);
        write({ id: msg.id, result });
        return;
      }
      write({ id: msg.id, error: `unknown method ${msg.method ?? ''}` });
    } catch (e) {
      write({ id: msg.id, error: (e as Error).message });
    }
  }
}
