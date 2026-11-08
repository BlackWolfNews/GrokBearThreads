// Stand-in for `grok agent stdio`. Speaks just enough ACP for the adapter test.
// When the prompt says END or DELETE, it spawns the session's MCP server the
// way Grok would and calls that tool, then also announces the call itself so
// the adapter can drop the duplicate.
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const rl = readline.createInterface({ input: process.stdin });
let sessionId;
let promptId;
let mcpServers = [];

function send(msg) {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
}

function mcpCall(server, name, args) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    for (const entry of server.env ?? []) env[entry.name] = entry.value;
    const child = spawn(server.command, server.args ?? [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    const out = readline.createInterface({ input: child.stdout });
    let stderr = '';
    child.stderr.on('data', (buf) => {
      stderr += buf.toString();
    });
    let id = 1;
    const pending = new Map();
    const write = (msg) => child.stdin.write(`${JSON.stringify(msg)}\n`);
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`mcp timed out${stderr ? `: ${stderr.trim()}` : ''}`));
    }, 4000);
    out.on('line', (line) => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return;
      }
      if (msg.id === undefined) return;
      const waiter = pending.get(msg.id);
      if (!waiter) return;
      pending.delete(msg.id);
      if (msg.error) waiter.reject(new Error(msg.error.message || 'mcp error'));
      else waiter.resolve(msg.result);
    });
    const request = (method, params) => new Promise((res, rej) => {
      const msgId = id++;
      pending.set(msgId, { resolve: res, reject: rej });
      write({ jsonrpc: '2.0', id: msgId, method, params });
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    void (async () => {
      try {
        const init = await request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'fake-grok', version: '0' } });
        if (!init?.instructions) throw new Error('threadbear server sent no instructions');
        write({ jsonrpc: '2.0', method: 'notifications/initialized' });
        const listed = await request('tools/list', {});
        if (!listed.tools?.some((t) => t.name === name)) throw new Error(`missing tool ${name}`);
        const result = await request('tools/call', { name, arguments: args });
        clearTimeout(timer);
        child.kill();
        resolve(result);
      } catch (e) {
        clearTimeout(timer);
        child.kill();
        reject(new Error(`${e instanceof Error ? e.message : String(e)}${stderr ? `: ${stderr.trim()}` : ''}`));
      }
    })();
  });
}

rl.on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') {
    send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: 1, _meta: { agentVersion: 'test' } } });
    return;
  }
  if (msg.method === 'session/new' || (msg.method === 'session/load' && msg.params.sessionId !== 'missing')) {
    mcpServers = msg.params.mcpServers ?? [];
    sessionId = msg.method === 'session/new' ? 'grok-sess-1' : msg.params.sessionId;
    send({ jsonrpc: '2.0', id: msg.id, result: { sessionId } });
    return;
  }
  if (msg.method === 'session/load') {
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: 'session not found' } });
    return;
  }
  if (msg.method === 'session/prompt') {
    promptId = msg.id;
    const text = msg.params.prompt?.[0]?.text ?? '';
    const reply = async () => {
      if (text.includes('ASK')) {
        send({
          jsonrpc: '2.0',
          id: 50,
          method: 'session/request_permission',
          params: {
            sessionId,
            toolCall: { toolCallId: 'call-1', title: 'Run ls', kind: 'execute', rawInput: { command: 'ls' } },
            options: [
              { optionId: 'allow', kind: 'allow_once', name: 'Allow' },
              { optionId: 'reject', kind: 'reject_once', name: 'Reject' },
            ],
          },
        });
        return;
      }
      if (text.includes('END') || text.includes('DELETE')) {
        const server = mcpServers[0];
        if (!server?.command) throw new Error('session has no mcp server');
        const name = text.includes('DELETE') ? 'delete_thread' : 'end_turn';
        const args = text.includes('DELETE') ? { threadId: 'abc' } : { needs: 'nothing' };
        await mcpCall(server, name, args);
        send({
          jsonrpc: '2.0',
          method: 'session/update',
          params: { sessionId, update: { sessionUpdate: 'tool_call', toolCallId: 'grok-use-1', title: 'use_tool', kind: 'other', rawInput: { tool_name: name, tool_input: args } } },
        });
        send({
          jsonrpc: '2.0',
          method: 'session/update',
          params: { sessionId, update: { sessionUpdate: 'tool_call', toolCallId: 'grok-copy-1', title: name, kind: 'other', rawInput: args } },
        });
        send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } });
        return;
      }
      send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Hello ' } } } });
      send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'there' } } } });
      send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } });
    };
    void reply().catch((e) => {
      send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e instanceof Error ? e.message : String(e) } });
    });
    return;
  }
  if (msg.id !== undefined && msg.result) {
    const allow = msg.result.outcome?.optionId === 'allow';
    send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: allow ? 'allowed' : 'denied' } } } });
    send({ jsonrpc: '2.0', id: promptId, result: { stopReason: 'end_turn' } });
  }
});
