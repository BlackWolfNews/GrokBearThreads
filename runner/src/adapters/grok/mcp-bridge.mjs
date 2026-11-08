// Stdio MCP server that `grok agent stdio` spawns for one thread.
// It has no tools of its own. tools/list and tools/call go over a unix
// socket to the runner, which runs the same handlers Claude's in-process
// server runs. Stdout is JSON-RPC only; logs go to stderr.
import net from 'node:net';
import readline from 'node:readline';

const socketPath = process.argv[2];
if (!socketPath) {
  process.stderr.write('threadbear grok bridge: no socket path\n');
  process.exit(1);
}

const parent = net.createConnection(socketPath);
parent.on('error', (e) => {
  process.stderr.write(`threadbear grok bridge: ${e.message}\n`);
  process.exit(1);
});

let parentBuf = '';
const pending = new Map();

parent.on('data', (buf) => {
  parentBuf += buf.toString('utf8');
  let nl = parentBuf.indexOf('\n');
  while (nl >= 0) {
    const line = parentBuf.slice(0, nl);
    parentBuf = parentBuf.slice(nl + 1);
    nl = parentBuf.indexOf('\n');
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    const waiter = pending.get(msg.id);
    if (!waiter) continue;
    pending.delete(msg.id);
    if (msg.error) waiter.reject(new Error(typeof msg.error === 'string' ? msg.error : msg.error.message || 'bridge error'));
    else waiter.resolve(msg.result);
  }
});

let nextId = 1;
function parentRequest(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    parent.write(`${JSON.stringify({ id, method, params })}\n`);
  });
}

function send(msg) {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
}

let listed;

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  void handle(msg);
});
process.stdin.on('end', () => process.exit(0));

async function handle(msg) {
  if (msg.id === undefined) return;
  try {
    if (msg.method === 'initialize') {
      listed = await parentRequest('hello', {});
      send({
        jsonrpc: '2.0',
        id: msg.id,
        result: {
          protocolVersion: msg.params?.protocolVersion || '2024-11-05',
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: 'threadbear', version: '0.0.0' },
          ...(listed.instructions ? { instructions: listed.instructions } : {}),
        },
      });
      return;
    }
    if (msg.method === 'ping') {
      send({ jsonrpc: '2.0', id: msg.id, result: {} });
      return;
    }
    if (msg.method === 'tools/list') {
      if (!listed) listed = await parentRequest('hello', {});
      send({ jsonrpc: '2.0', id: msg.id, result: { tools: listed.tools ?? [] } });
      return;
    }
    if (msg.method === 'tools/call') {
      const result = await parentRequest('call', {
        name: msg.params?.name,
        arguments: msg.params?.arguments ?? {},
      });
      send({ jsonrpc: '2.0', id: msg.id, result });
      return;
    }
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: `unknown method ${msg.method}` } });
  } catch (e) {
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e instanceof Error ? e.message : String(e) } });
  }
}
