// `threadbear setup`: sets Threadbear up on this Mac from a clone of the repo
// (docs/setup-and-updates.md section 2.2). Every step looks at what's already
// there first, so running it again only does what's missing, and --dry-run
// says what it would do without doing any of it.
//
//   ./threadbear setup [--dry-run] [--yes] [--team SLUG] [--project NAME]
//                      [--region REGION] [--cwd DIR] [--name NAME]
//                      [--home DIR] [--skip-install] [--existing]
//
//   1. this Mac: macOS, Xcode's command line tools, git, Node 24, Claude Code
//      or Codex, and Tailscale (optional)
//   2. the repo's packages
//   3. a Convex login, then a Convex project of your own with a production
//      deployment (a new one, the one this clone already uses, or with
//      --existing the project named by --project, for a second Mac)
//   4. its keys: a deploy key the runner uses to deploy the backend when it
//      updates, and the runner's own key, set as RUNNER_KEY
//   5. runner.json: where the runner mirrors to, and your default folder
//   6. the backend and the website, deployed
//   7. the runner and the Mac app, built and installed
//   8. how to pair your iPhone and sign a browser in
//
// Node built-ins only, so it runs before the repo's packages are installed.
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline/promises';
import { parseArgs } from 'node:util';

const repo = path.resolve(import.meta.dirname, '..');
const DEFAULT_HOME = path.join(os.homedir(), 'Library', 'Application Support', 'Threadbear');

const { values: v } = parseArgs({
  options: {
    'dry-run': { type: 'boolean' },
    yes: { type: 'boolean', short: 'y' },
    team: { type: 'string' },
    project: { type: 'string', default: 'threadbear' },
    region: { type: 'string' },
    cwd: { type: 'string' },
    name: { type: 'string' },
    home: { type: 'string' },
    'skip-install': { type: 'boolean' },
    existing: { type: 'boolean' },
    help: { type: 'boolean', short: 'h' },
  },
});
if (v.help) {
  const lines = fs.readFileSync(new URL(import.meta.url), 'utf8').split('\n');
  console.log(lines.slice(0, lines.findIndex((l) => l.startsWith('import'))).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const dry = Boolean(v['dry-run']);
const home = path.resolve((v.home ?? process.env.THREADBEAR_HOME ?? DEFAULT_HOME).replace(/^~(?=$|\/)/, os.homedir()));
const secrets = path.join(home, 'secrets');
const runnerJsonPath = path.join(home, 'runner.json');
const deployKeyFile = path.join(secrets, 'convex-deploy.env');
const runnerKeyFile = path.join(secrets, 'convex-key');
const npx = path.join(path.dirname(process.execPath), 'npx');
const npm = path.join(path.dirname(process.execPath), 'npm');

class Fail extends Error {}
const say = (s = '') => console.log(s);
const ok = (s) => say(`  ✓ ${s}`);
const todo = (s) => say(`  → ${s}`);
const note = (s) => say(`  · ${s}`);

function run(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { cwd: repo, encoding: 'utf8', ...opts });
}
function runOrFail(what, cmd, args, opts = {}) {
  const r = run(cmd, args, { stdio: 'inherit', ...opts });
  if (r.status !== 0) throw new Fail(`${what} failed (${cmd} ${args.join(' ')}).`);
  return r;
}
function has(cmd) {
  return run('/bin/zsh', ['-lc', `command -v ${cmd}`]).status === 0;
}
function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return {};
  }
}
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(value, null, 2) + '\n');
  fs.renameSync(`${file}.tmp`, file);
}
function writeSecret(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, text, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// The deploy key, read and never printed; its "prod:<name>|" prefix names the deployment.
function deployKey() {
  try {
    const key = fs.readFileSync(deployKeyFile, 'utf8').match(/^CONVEX_DEPLOY_KEY=["']?([^"'\n]+)/m)?.[1];
    return key ? { key, name: key.match(/^[a-z]+:([a-z0-9-]+)\|/)?.[1] } : undefined;
  } catch {
    return undefined;
  }
}
// Convex commands against the production deployment, picked by the deploy
// key alone so a stray CONVEX_DEPLOYMENT can't point them anywhere else.
function withKey(key) {
  const env = { ...process.env, CONVEX_DEPLOY_KEY: key };
  delete env.CONVEX_DEPLOYMENT;
  return env;
}

async function ask(question, fallback) {
  if (v.yes || !process.stdin.isTTY) return fallback;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = (await rl.question(`  ${question} [${fallback}] `)).trim();
  rl.close();
  return answer || fallback;
}

// ------------------------------------------------------------ the steps

function checkMac() {
  say('1. This Mac');
  if (process.platform !== 'darwin') throw new Fail('Threadbear runs on macOS.');
  ok(`macOS ${os.release()} on ${os.arch()}`);
  if (run('xcode-select', ['-p']).status !== 0) throw new Fail("Xcode's command line tools aren't installed. Run: xcode-select --install");
  ok("Xcode's command line tools");
  if (!has('git')) throw new Fail('git is missing.');
  ok('git');
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 24) throw new Fail(`Node ${process.versions.node} is too old; Threadbear needs 24 or newer.`);
  ok(`Node ${process.versions.node} (${process.execPath})`);
  const claude = fs.existsSync(path.join(os.homedir(), '.local', 'bin', 'claude')) || has('claude');
  const codex = has('codex');
  if (!claude && !codex) throw new Fail('Neither Claude Code nor Codex is installed. Install one and log in first: https://claude.com/claude-code or https://developers.openai.com/codex');
  ok([claude && 'Claude Code', codex && 'Codex'].filter(Boolean).join(' and '));
  // The runner is a login agent, which macOS only loads for someone logged in
  // to the desktop: over SSH to a Mac nobody's logged in to, step 7 can't
  // finish (seen on Tinker Desk, 28 Oct).
  if (desktopSession()) ok('logged in to the desktop');
  else note("Nobody is logged in to this Mac's desktop. Everything up to installing the runner works, then setup stops: log in (in person or with Screen Sharing) and run it again.");
  if (fs.existsSync('/Applications/Tailscale.app') || has('tailscale')) ok('Tailscale');
  else note("Tailscale isn't installed. Threadbear works without it; with it, a second Mac can run threads too (https://tailscale.com/download).");
}

function desktopSession() {
  return run('launchctl', ['print', `gui/${process.getuid()}`]).status === 0;
}

function packages() {
  say('2. Packages');
  if (fs.existsSync(path.join(repo, 'node_modules', 'convex'))) return ok('installed');
  if (dry) return todo('npm ci');
  runOrFail('npm ci', npm, ['ci', '--no-audit', '--no-fund']);
  ok('installed');
}

function convexLogin() {
  say('3. Convex');
  const config = readJson(path.join(os.homedir(), '.convex', 'config.json'));
  if (config.accessToken) ok('logged in to Convex');
  else if (dry) todo('npx convex login (opens the browser)');
  else {
    // Opens the browser and waits for the approval there, with no questions
    // in the terminal, so an agent can run setup too (INSTALL.md).
    runOrFail('Logging in to Convex', npx, ['convex', 'login', '--device-name', os.hostname().split('.')[0], '--login-flow', 'poll']);
    ok('logged in to Convex');
  }
}

// The production deployment's URL. Read from runner.json when setup has
// already run; otherwise made here.
async function project() {
  const json = readJson(runnerJsonPath);
  const key = deployKey();
  if (json.sync?.url && key) {
    ok(`using ${json.sync.url}`);
    return json.sync.url;
  }
  const selected = fs.existsSync(path.join(repo, '.env.local')) && /CONVEX_DEPLOYMENT=/.test(fs.readFileSync(path.join(repo, '.env.local'), 'utf8'));
  if (!selected) {
    const verb = v.existing ? 'use the existing' : 'create a';
    if (dry) return todo(`${verb} Convex project "${v.project}"${v.team ? ` on team ${v.team}` : ''} with a dev deployment`), undefined;
    const args = ['convex', 'dev', '--once', '--configure', v.existing ? 'existing' : 'new', '--project', v.project, '--dev-deployment', 'cloud'];
    const team = v.team ?? onlyTeam();
    if (team) args.push('--team', team);
    runOrFail(v.existing ? 'Selecting the Convex project' : 'Creating the Convex project', npx, args);
    ok(`project ${v.project}`);
  } else ok('this clone already has a Convex project (.env.local)');
  if (dry) return todo('create its production deployment'), undefined;
  const args = ['convex', 'deployment', 'create', 'production', '--type', 'prod', '--default'];
  if (v.region) args.push('--region', v.region);
  const made = run(npx, args);
  const text = `${made.stdout}\n${made.stderr}`;
  let url = text.match(/https:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)?\.convex\.cloud/)?.[0];
  if (!url) {
    // It may exist already (a second run after a failure): find its URL from the key.
    note('the production deployment may already exist; looking for it');
  }
  return url;
}

async function keys(urlFromProject) {
  say('4. Keys');
  if (!deployKey()) {
    if (dry) todo(`a deploy key in ${deployKeyFile}`);
    else {
      fs.mkdirSync(secrets, { recursive: true, mode: 0o700 });
      runOrFail('Making a deploy key', npx, ['convex', 'deployment', 'token', 'create', `threadbear-runner-${os.hostname().split('.')[0].toLowerCase()}`, '--prod', '--save-env', deployKeyFile]);
      fs.chmodSync(deployKeyFile, 0o600);
      ok(`deploy key saved in ${deployKeyFile}`);
    }
  } else ok('deploy key');
  const key = deployKey();
  let url = urlFromProject ?? readJson(runnerJsonPath).sync?.url;
  if (!url && key?.name) url = await findUrl(key.name);
  if (!dry && !url) throw new Fail("Couldn't work out the production deployment's URL. Put it in runner.json as sync.url and run setup again.");
  if (fs.existsSync(runnerKeyFile) && dry) ok('runner key');
  if (!fs.existsSync(runnerKeyFile)) {
    if (dry) todo('a runner key, set on the deployment as RUNNER_KEY');
    else writeSecret(runnerKeyFile, crypto.randomBytes(32).toString('hex'));
  }
  if (!dry && key) {
    const want = fs.readFileSync(runnerKeyFile, 'utf8').trim();
    const got = run(npx, ['convex', 'env', 'get', 'RUNNER_KEY'], { env: withKey(key.key) }).stdout.trim();
    if (got !== want) {
      const r = spawnSync(npx, ['convex', 'env', 'set', 'RUNNER_KEY'], { cwd: repo, env: withKey(key.key), input: want, encoding: 'utf8' });
      if (r.status !== 0) throw new Fail('Setting RUNNER_KEY on the deployment failed.');
    }
    ok('runner key set as RUNNER_KEY');
  }
  return url;
}

// The team to use when none was given: the only one there is. With several,
// Convex asks in the terminal; with nobody there to answer (an agent), setup
// stops and lists them instead.
function onlyTeam() {
  const out = run(npx, ['convex', 'login', 'status']).stdout ?? '';
  const teams = [...out.matchAll(/^\s+- (.+) \(([^)]+)\)$/gm)].map((m) => ({ name: m[1], slug: m[2] }));
  if (teams.length === 1) return teams[0].slug;
  if (process.stdin.isTTY && !v.yes) return undefined;
  throw new Fail(`Your Convex login has ${teams.length} teams. Run setup again with --team and one of: ${teams.map((t) => `${t.slug} (${t.name})`).join(', ')}.`);
}

// Probes the regions Convex runs in for a deployment's URL.
async function findUrl(name) {
  for (const region of ['', 'ap-southeast-2.', 'eu-west-1.', 'us-east-1.', 'us-west-2.']) {
    const url = `https://${name}.${region}convex.cloud`;
    try {
      const res = await fetch(`${url}/version`, { signal: AbortSignal.timeout(5000) });
      if (res.ok) return url;
    } catch {
      // not this one
    }
  }
  return undefined;
}

async function runnerJson(url) {
  say('5. runner.json');
  const json = readJson(runnerJsonPath);
  const name = v.name ?? json.sync?.name ?? os.hostname().split('.')[0];
  const cwd = v.cwd ?? json.defaults?.cwd ?? (await ask('Folder new threads start in?', '~'));
  const next = { ...json, sync: { ...json.sync, ...(url ? { url } : {}), name }, defaults: { ...json.defaults, cwd } };
  if (JSON.stringify(next) === JSON.stringify(json)) return ok(`${runnerJsonPath} as it was`);
  if (dry) return todo(`write ${runnerJsonPath}: sync.url ${url ?? '(the new deployment)'}, sync.name ${name}, defaults.cwd ${cwd}`);
  writeJson(runnerJsonPath, next);
  ok(`mirrors to ${url} as ${name}; new threads start in ${cwd}`);
}

function backend() {
  say('6. Backend and website');
  if (dry) return todo('node runner/scripts/deploy-backend.mjs (deploys convex/ and web/ if they changed)');
  runOrFail('Deploying the backend', process.execPath, [path.join(repo, 'runner', 'scripts', 'deploy-backend.mjs'), '--home', home, '--repo', repo]);
}

function install() {
  say('7. Runner and Mac app');
  if (v['skip-install']) return note('skipped (--skip-install)');
  if (dry) return todo('runner/scripts/install-runner.sh, then app/install.sh');
  if (!desktopSession()) throw new Fail("Nobody is logged in to this Mac's desktop, and macOS only starts the runner (a login agent) for someone who is. Log in, in person or with Screen Sharing, then run setup again.");
  const env = { ...process.env, THREADBEAR_NODE: process.execPath };
  const homeArgs = path.resolve(home) === DEFAULT_HOME ? [] : ['--home', home];
  runOrFail('Installing the runner', 'bash', [path.join(repo, 'runner', 'scripts', 'install-runner.sh'), ...homeArgs], { env });
  runOrFail('Installing the Mac app', 'bash', [path.join(repo, 'app', 'install.sh')], { env });
  ok('runner and app installed');
}

function finish(url) {
  say('8. Your phone and browser');
  const at = url ?? '<your deployment URL>';
  note('Pair the Threadbear iPhone app (it shows a code to scan):');
  say(`      swift ios/scripts/pair-qr.swift --prod --url ${at}`);
  note('Sign a browser in to your Threadbear website:');
  say('      npm run web:sign-in');
}

try {
  say(dry ? 'Threadbear setup (dry run: nothing changes)\n' : 'Threadbear setup\n');
  checkMac();
  say();
  packages();
  say();
  convexLogin();
  const made = await project();
  say();
  const url = await keys(made);
  say();
  await runnerJson(url);
  say();
  backend();
  say();
  install();
  say();
  finish(url);
  say(dry ? '\nDry run done.' : '\nThreadbear is set up.');
} catch (e) {
  if (!(e instanceof Fail)) throw e;
  console.error(`\n✗ ${e.message}\nFix that and run setup again; it carries on from where it stopped.`);
  process.exit(1);
}
