// runner/scripts/deploy-backend.mjs with another deploy already running: it
// waits for that one rather than failing, then deploys only what's still
// left. On 6 Nov an old runner handing over was deploying main's backend
// while the new runner started its own for the same commit, and the second
// one's "Another backend deploy is running" stopped the update.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { tmpDir } from '../helpers/fakes.ts';

const repo = path.resolve(import.meta.dirname, '../../..');
const script = path.join(repo, 'runner/scripts/deploy-backend.mjs');

// The same hashes the script compares (its treeOf).
function treeOf(paths: string[]): string {
  const out = spawnSync('git', ['-C', repo, 'ls-tree', 'HEAD', '--', ...paths], { encoding: 'utf8' }).stdout;
  return out.split('\n').filter(Boolean).map((l) => l.split(/\s+/)[2]).join('+');
}

test('a second backend deploy waits for the first, then has nothing left to do', async () => {
  const home = tmpDir();
  fs.mkdirSync(path.join(home, 'secrets'), { recursive: true });
  // A made-up deployment: if the wait were wrong, nothing real is reached.
  fs.writeFileSync(path.join(home, 'secrets', 'convex-deploy.env'), 'CONVEX_DEPLOY_KEY=prod:no-such-deploy-000|x\n');
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ sync: { url: 'https://no-such-deploy-000.example.invalid' } }));
  const done = {
    functions: { tree: treeOf(['convex', 'convex.json', 'package.json', 'package-lock.json']) },
    site: { tree: treeOf(['web', 'package.json', 'package-lock.json']) },
  };
  // The first deploy: holds the kernel lock the script takes, records its
  // deploy, then lets go.
  const lockFile = path.join(home, 'backend.flock');
  const record = `setTimeout(() => require('fs').writeFileSync(${JSON.stringify(path.join(home, 'backend.json'))}, ${JSON.stringify(JSON.stringify(done))}), 1500)`;
  const holder = process.platform === 'darwin' ? ['/usr/bin/lockf', ['-k', lockFile, process.execPath, '-e', record]] as const : ['flock', [lockFile, process.execPath, '-e', record]] as const;
  const first = spawn(holder[0], [...holder[1]], { stdio: 'ignore' });
  const firstDone = new Promise((resolve) => first.on('close', resolve));
  // Until it holds the lock.
  while (!fs.existsSync(lockFile)) await new Promise((r) => setTimeout(r, 20));
  const r = await new Promise<{ status: number | null; out: string }>((resolve) => {
    const c = spawn(process.execPath, [script, '--home', home, '--repo', repo], { env: { ...process.env, PATH: '/usr/bin:/bin' } });
    let out = '';
    c.stdout.on('data', (d) => (out += d));
    c.stderr.on('data', (d) => (out += d));
    c.on('close', (status) => resolve({ status, out }));
  });
  assert.equal(r.status, 0, r.out);
  assert.match(r.out, /Waiting for another backend deploy/);
  assert.match(r.out, /up to date/);
  await firstDone;
});

