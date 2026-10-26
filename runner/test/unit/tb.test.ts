import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { makeHarness } from '../helpers/fakes.ts';
import { RpcServer } from '../../src/rpc.ts';
import fs from 'node:fs';
import os from 'node:os';
import { loadConfig, readToken, runnerUrl } from '../../src/config.ts';
import { nullLogger } from '../../src/log.ts';

const TB = path.join(import.meta.dirname, '..', '..', 'bin', 'tb');

async function serve() {
  const h = makeHarness();
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: readToken(h.home), runner: h.runner, log: nullLogger });
  const { port } = await server.listen();
  return { h, server, url: `ws://127.0.0.1:${port}/rpc` };
}

function tb(h: { home: string }, url: string, args: string[]) {
  let out = '';
  const p = spawn(process.execPath, [TB, ...args], { env: { ...process.env, THREADBARE_HOME: h.home, THREADBARE_URL: url }, stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.on('data', (d) => (out += d));
  p.stderr.on('data', (d) => (out += d));
  const exited = new Promise<number | null>((r) => p.once('exit', (code) => r(code)));
  return { out: () => out, exited, kill: () => p.kill() };
}

const settled = (p: Promise<unknown>, ms: number) => Promise.race([p.then(() => true), new Promise((r) => setTimeout(() => r(false), ms))]);

test('tb tail --until-done waits for the turn that is running, not an old one in the backlog', async () => {
  const { h, server, url } = await serve();
  const { thread } = h.runner.create({ text: 'first', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  s.text('m1:0', 'one');
  s.result();
  h.runner.send(thread.id, 'second');
  const t = tb(h, url, ['tail', thread.id.slice(0, 8), '--until-done']);
  try {
    assert.equal(await settled(t.exited, 1500), false, 'still tailing while the second turn runs');
    s.text('m2:0', 'two');
    s.result();
    assert.equal(await t.exited, 0);
    assert.match(t.out(), /one[\s\S]*> second[\s\S]*two/);
    // With nothing running it prints the backlog and stops.
    const idle = tb(h, url, ['tail', thread.id, '--until-done']);
    assert.equal(await idle.exited, 0);
  } finally {
    t.kill();
    await server.close();
  }
});

test('tb send --wait shows the new message and leaves the thread unread', async () => {
  const { h, server, url } = await serve();
  const { thread } = h.runner.create({ text: 'first', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  s.result();
  const seenBefore = h.runner.get(thread.id).lastSeenSeq;
  const t = tb(h, url, ['send', thread.id, 'hello there', '--wait']);
  try {
    for (let i = 0; i < 100 && s.sent.length < 2; i++) await new Promise((r) => setTimeout(r, 30));
    assert.equal(s.sent.length, 2);
    s.text('m2:0', 'hi back');
    s.result();
    assert.equal(await t.exited, 0);
    assert.match(t.out(), /> hello there[\s\S]*hi back/);
    assert.equal(h.runner.get(thread.id).lastSeenSeq, seenBefore, 'not marked seen');
  } finally {
    t.kill();
    await server.close();
  }
});

test('tb finds a runner on port 0 through runner.json, as the CLIs of a dev or sandbox runner must', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'tb-port-'));
  try {
    fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ port: 4242 }));
    const env = { THREADBARE_HOME: home, THREADBARE_PORT: '0' };
    assert.equal(runnerUrl(loadConfig(env), env), 'ws://127.0.0.1:4242/rpc');
    const fixed = { THREADBARE_HOME: home, THREADBARE_PORT: '5151' };
    assert.equal(runnerUrl(loadConfig(fixed), fixed), 'ws://127.0.0.1:5151/rpc');
    const url = { ...env, THREADBARE_URL: 'ws://127.0.0.1:1/rpc' };
    assert.equal(runnerUrl(loadConfig(url), url), 'ws://127.0.0.1:1/rpc');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
