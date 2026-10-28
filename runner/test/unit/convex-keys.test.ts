import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import { ConvexKeys, cliError, convexFolderFor } from '../../src/convex-keys.ts';
import type { CommandOutcome } from '../../src/patches.ts';

// Stands in for `npx convex deployment token create ... --save-env <file>`.
function fakeCli(key = 'dev:calm-cat-1|secretsecret') {
  const calls: { command: string; cwd: string }[] = [];
  const run = async (command: string, cwd: string): Promise<CommandOutcome> => {
    calls.push({ command, cwd });
    const file = /--save-env '([^']+)'/.exec(command)?.[1];
    if (file) fs.writeFileSync(file, `CONVEX_DEPLOY_KEY=${key}\n`);
    return { ok: true, text: '✔ Saved deploy key', truncated: false, durationMs: 1 };
  };
  return { calls, run };
}

test('a deploy key is made once per deployment, kept private, and made again on renew', async () => {
  const dir = path.join(tmpDir(), 'secrets', 'convex-panels');
  const cli = fakeCli();
  const keys = new ConvexKeys(dir, cli.run, 'Mikes-MacBook.local');
  const [a, b] = await Promise.all([keys.key('calm-cat-1', '/proj'), keys.key('calm-cat-1', '/proj')]);
  assert.equal(a, 'dev:calm-cat-1|secretsecret');
  assert.equal(b, a);
  assert.equal(cli.calls.length, 1, 'two panels opening together make one key');
  const name = /token create (threadbear-panel-mikes-macbook-[0-9a-f]{6}) --deployment calm-cat-1 --save-env '/.exec(cli.calls[0].command)?.[1];
  assert.ok(name, cli.calls[0].command);
  assert.match(cli.calls[0].command, /^npx --no-install convex /);
  assert.equal(cli.calls[0].cwd, '/proj');
  const file = path.join(dir, 'calm-cat-1.json');
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  assert.deepEqual(fs.readdirSync(dir), ['calm-cat-1.json'], 'the CLI\'s scratch file is gone');
  assert.equal(await keys.key('calm-cat-1', '/proj'), a);
  assert.equal(cli.calls.length, 1, 'kept for next time');
  // Renewing takes the old key off Convex, then makes one with a new name
  // (names are unique on a deployment).
  await keys.key('calm-cat-1', '/proj', true);
  assert.equal(cli.calls[1].command, `npx --no-install convex deployment token delete ${name} --deployment calm-cat-1`);
  assert.match(cli.calls[2].command, /token create threadbear-panel-mikes-macbook-[0-9a-f]{6} /);
  assert.ok(!cli.calls[2].command.includes(name!));
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).name, /token create (\S+)/.exec(cli.calls[2].command)![1]);
});

test('a failed CLI call says why, without making a key file', async () => {
  const dir = path.join(tmpDir(), 'convex-panels');
  const keys = new ConvexKeys(dir, async () => ({ ok: false, text: '\x1b[31m✖ Error: You are not logged in. Run `npx convex login`.\x1b[0m\n', truncated: false, durationMs: 1 }));
  await assert.rejects(keys.key('calm-cat-1', '/proj'), /Couldn't make a deploy key for calm-cat-1: Error: You are not logged in\. Run `npx convex login`\./);
  assert.deepEqual(fs.readdirSync(dir), []);
  await assert.rejects(keys.key('x; rm -rf ~', '/proj'), /isn't a Convex deployment name/);
  assert.equal(cliError(''), 'the Convex CLI gave no reason');
});

test('the project folder for a deployment is the thread\'s or one of its projects\'', () => {
  const home = tmpDir();
  const mk = (rel: string, deployment: string) => {
    const dir = path.join(home, rel);
    fs.mkdirSync(path.join(dir, 'convex'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'package.json'), '{}');
    fs.writeFileSync(path.join(dir, '.env.local'), `CONVEX_DEPLOYMENT=dev:${deployment}\n`);
    return dir;
  };
  const app = mk('dev/app', 'app-1');
  const web = mk('dev/web', 'web-2');
  fs.mkdirSync(path.join(app, 'src'));
  assert.equal(convexFolderFor('app-1', [path.join(app, 'src'), web], home), app);
  assert.equal(convexFolderFor('web-2', [path.join(app, 'src'), web], home), web);
  assert.equal(convexFolderFor('other-3', [app, web], home), undefined);
});

test('deployment choices resolve dev and prod through the CLI without changing project settings or making keys', async () => {
  const folder = tmpDir();
  fs.writeFileSync(path.join(folder, '.env.local'), 'CONVEX_DEPLOYMENT=dev:calm-cat-1\n');
  const calls: string[] = [];
  const keys = new ConvexKeys(path.join(folder, 'keys'), async (command, cwd) => {
    assert.equal(cwd, folder);
    calls.push(command);
    return { ok: true, text: JSON.stringify(command.includes('--deployment prod')
      ? 'https://busy-bear-2.ap-southeast-2.convex.cloud' : 'https://calm-cat-1.convex.cloud'), truncated: false, durationMs: 1 };
  });
  const configured = { deployment: 'calm-cat-1', deploymentUrl: 'https://calm-cat-1.convex.cloud' };
  const listed = await keys.deployments(folder, configured);
  assert.deepEqual(listed, { deployments: [
    { ...configured, label: 'Development' },
    { deployment: 'busy-bear-2', deploymentUrl: 'https://busy-bear-2.ap-southeast-2.convex.cloud', label: 'Production' },
  ] });
  assert.ok(calls.every(c => c.includes('run --inline-query') && !c.includes('--push') && !c.includes('token')));
  assert.deepEqual(await keys.deployments(folder, configured), listed);
  assert.equal(calls.length, 2, 'discovery is cached');
  await keys.deployments(folder, configured, true);
  assert.equal(calls.length, 4, 'refresh bypasses the cache');
  assert.equal(fs.readFileSync(path.join(folder, '.env.local'), 'utf8'), 'CONVEX_DEPLOYMENT=dev:calm-cat-1\n');
  assert.ok(!fs.existsSync(path.join(folder, 'keys')));
});

test('unavailable choices leave the configured deployment usable and explain why', async () => {
  const folder = tmpDir();
  const configured = { deployment: 'calm-cat-1', deploymentUrl: 'https://calm-cat-1.convex.cloud' };
  const keys = new ConvexKeys(path.join(folder, 'keys'), async () => ({ ok: false, text: 'No production deployment', truncated: false, durationMs: 1 }));
  const listed = await keys.deployments(folder, configured);
  assert.deepEqual(listed.deployments, [{ ...configured, label: 'Configured' }]);
  assert.match(listed.note!, /Production: No production deployment/);
});
