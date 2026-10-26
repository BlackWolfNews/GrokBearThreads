// Stands in for src/main.ts in the deploy tests: the test commits it as
// runner/src/main.ts in a throwaway repo, so releases are tiny and need no
// packages (their npm ci installs nothing). It speaks just enough of the
// protocol over a hand-rolled WebSocket: auth, hello, runner.status,
// runner.restart and threads.list.
//
// mode.json next to it sets how this commit behaves:
//   crash: "always" | "launched"  exit 1 at startup; "launched" only under
//                                 launch.mjs (not in the smoke test)
//   oldRunner: true               no runner.restart, like runners before it
//   goodAfterMs: n                mark lastGood after n ms (default 200, -1 never)
// <home>/fake-busy.json lists the threads that count as running, and while
// <home>/fake-hang-restart exists runner.restart never answers (a runner
// too busy to reply).
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const here = import.meta.dirname;
const mode = JSON.parse(fs.readFileSync(path.join(here, 'mode.json'), 'utf8'));
const home = process.env.THREADBARE_HOME;
const release = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(here, '..', 'release.json'), 'utf8')).id;
  } catch {
    return null;
  }
})();
const version = `9.9.9+${release ?? 'source'}`;
// The contract with launch.mjs: state.json lives in <THREADBARE_HOME>/runner,
// which only exists for an installed runner, never in the smoke test.
const stateFile = path.join(home, 'runner', 'state.json');
const launched = fs.existsSync(stateFile);

console.log(`fake runner ${version} starting (pid ${process.pid})`);
if (mode.crash === 'always' || (mode.crash === 'launched' && launched)) {
  console.log('fake runner: crashing on purpose');
  process.exit(1);
}

fs.mkdirSync(path.join(home, 'secrets'), { recursive: true });
const tokenFile = path.join(home, 'secrets', 'runner-token');
if (!fs.existsSync(tokenFile)) fs.writeFileSync(tokenFile, crypto.randomBytes(16).toString('hex') + '\n', { mode: 0o600 });
const token = fs.readFileSync(tokenFile, 'utf8').trim();
const startedAt = new Date().toISOString();

// Like main.ts: launch.mjs's watchdog applies, and a clean exit after
// listening isn't counted as a crash.
export const REPORTS_LISTENING = true;
let pending = null;

const busy = () => {
  try {
    return JSON.parse(fs.readFileSync(path.join(home, 'fake-busy.json'), 'utf8'));
  } catch {
    return [];
  }
};

function writeJsonAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

function handle(method, params) {
  switch (method) {
    case 'hello':
      return { runnerVersion: version, protocol: 1, accounts: [], defaults: { cwd: '/tmp' } };
    case 'runner.status':
      if (mode.oldRunner) break;
      return {
        version,
        release: release ?? undefined,
        pid: process.pid,
        startedAt,
        home,
        liveClis: 0,
        running: busy(),
        background: [],
        ...(pending ? { pendingRestart: { ...pending, waitingFor: busy() } } : {}),
      };
    case 'threads.list':
      return { threads: busy().map((id) => ({ id, title: `Thread ${id}`, status: 'running' })) };
    case 'runner.restart': {
      if (mode.oldRunner) break;
      fs.appendFileSync(path.join(home, 'fake-restart-calls.ndjson'), JSON.stringify(params) + '\n');
      if (fs.existsSync(path.join(home, 'fake-hang-restart'))) return NO_REPLY;
      const waitingFor = params.when === 'now' ? [] : busy();
      pending = { when: params.when ?? 'idle', requestedAt: new Date().toISOString(), release: params.release, resumeThreadId: params.resume?.threadId };
      // Like the real one: exit 0 once nothing is running, and launchd
      // (here the fake one) starts it again.
      const timer = setInterval(() => {
        if (params.when === 'now' || busy().length === 0) {
          clearInterval(timer);
          setTimeout(() => process.exit(0), 50);
        }
      }, 100);
      return { scheduled: true, waitingFor };
    }
  }
  throw Object.assign(new Error(`Unknown method ${method}`), { code: -32601 });
}

const NO_REPLY = Symbol('no reply');

// The smallest WebSocket server that works with Node's WebSocket client:
// the upgrade handshake, masked client frames in, unmasked text frames out.
function frame(text) {
  const body = Buffer.from(text);
  const head = body.length < 126 ? Buffer.from([0x81, body.length]) : Buffer.from([0x81, 126, body.length >> 8, body.length & 0xff]);
  return Buffer.concat([head, body]);
}

const server = http.createServer((req, res) => {
  res.writeHead(404);
  res.end();
});
server.on('upgrade', (req, socket) => {
  const accept = crypto
    .createHash('sha1')
    .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buf = Buffer.alloc(0);
  let authed = false;
  socket.on('error', () => {});
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const opcode = buf[0] & 0x0f;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2));
        off = 10;
      }
      const masked = (buf[1] & 0x80) !== 0;
      if (buf.length < off + (masked ? 4 : 0) + len) return;
      const mask = masked ? buf.subarray(off, off + 4) : null;
      off += masked ? 4 : 0;
      const payload = Buffer.from(buf.subarray(off, off + len));
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      buf = buf.subarray(off + len);
      if (opcode === 0x8) {
        socket.end(Buffer.from([0x88, 0]));
        return;
      }
      if (opcode !== 0x1) continue;
      const msg = JSON.parse(payload.toString('utf8'));
      if (!authed) {
        if (msg.method === 'auth' && msg.params?.token === token) {
          authed = true;
          socket.write(frame(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} })));
        } else socket.end(Buffer.from([0x88, 0]));
        continue;
      }
      let reply;
      try {
        const result = handle(msg.method, msg.params ?? {});
        if (result === NO_REPLY) continue;
        reply = { jsonrpc: '2.0', id: msg.id, result };
      } catch (e) {
        reply = { jsonrpc: '2.0', id: msg.id, error: { code: e.code ?? -32000, message: e.message } };
      }
      socket.write(frame(JSON.stringify(reply)));
    }
  });
});

server.listen(Number(process.env.THREADBARE_PORT ?? 0), '127.0.0.1', () => {
  const { port } = server.address();
  writeJsonAtomic(path.join(home, 'runner.json'), { port });
  console.log(`threadbare-runner listening on ${port}`);
  globalThis.threadbareLaunch?.listening?.();
  const goodAfter = mode.goodAfterMs ?? 200;
  // main.ts does this after 60 s; the tests can't wait that long.
  if (launched && release && goodAfter >= 0) {
    setTimeout(() => {
      const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
      writeJsonAtomic(stateFile, { ...state, lastGood: release });
    }, goodAfter);
  }
});

process.on('SIGTERM', () => process.exit(0));
