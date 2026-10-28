// Deploy keys for the Convex panel (docs/protocol.md, "The Convex panel").
// Convex's embedded dashboard takes a deploy key instead of Mike's Convex
// login, so the runner makes one per deployment with the Convex CLI, on the
// CLI's own login, and keeps it under secrets/. A key never goes into a
// thread's events, the summary or the log: only panels.convexKey's answer.

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { CommandOutcome } from './patches.ts';
import { convexDeploymentName, findUp, isConvexProject, parseEnvValue, readEnvValue } from './patches.ts';

export type ConvexKey = { deployment: string; deploymentUrl: string; adminKey: string };
export type ConvexDeploymentChoice = { deployment: string; deploymentUrl: string; label: string };
export type ConvexDeployments = { deployments: ConvexDeploymentChoice[]; note?: string };
type Run = (command: string, cwd: string) => Promise<CommandOutcome>;

export class ConvexKeys {
  // One CLI call per deployment at a time: two panels opening together
  // would otherwise make two keys.
  private pending = new Map<string, Promise<string>>();
  private choices = new Map<string, { until: number; result: Promise<ConvexDeployments> }>();

  private dir: string;
  private run: Run;
  private host: string;

  // `dir` is secrets/convex-panels.
  constructor(dir: string, run: Run, host: string = os.hostname()) {
    this.dir = dir;
    this.run = run;
    this.host = host;
  }

  async deployments(folder: string, configured: { deployment: string; deploymentUrl: string }, refresh = false): Promise<ConvexDeployments> {
    const type = readEnvValue(folder, 'CONVEX_DEPLOYMENT')?.split(':')[0];
    const cacheKey = JSON.stringify([folder, configured, type]);
    const cached = this.choices.get(cacheKey);
    if (!refresh && cached && cached.until > Date.now()) return cached.result;
    const result = this.listDeployments(folder, configured, type);
    this.choices.set(cacheKey, { until: Date.now() + 60_000, result });
    return result;
  }

  private async listDeployments(folder: string, configured: { deployment: string; deploymentUrl: string }, type?: string): Promise<ConvexDeployments> {
    const deployments: ConvexDeploymentChoice[] = [{ ...configured,
      label: type === 'dev' ? 'Development' : type === 'prod' ? 'Production' : 'Configured' }];
    const notes: string[] = [];
    // The CLI resolves the project's default dev/prod with its own login.
    // Reading only this built-in URL also preserves regional cloud hosts.
    // No --push, codegen or writes to the project's env files.
    const resolved = await Promise.all(['dev', 'prod'].map(async selector => {
      const label = selector === 'prod' ? 'Production' : 'Development';
      try {
        const out = await this.run(`npx --no-install convex run --inline-query 'process.env.CONVEX_CLOUD_URL' --deployment ${selector} --codegen disable --typecheck disable`, folder);
        if (!out.ok) throw new Error(cliError(out.text));
        const url = new URL(JSON.parse(out.text.trim()));
        const deployment = convexDeploymentName(url.hostname.split('.')[0]);
        if (url.protocol !== 'https:' || !url.hostname.endsWith('.convex.cloud') || !deployment || url.username || url.password) {
          throw new Error('This deployment has no Convex cloud URL.');
        }
        return { deployment, deploymentUrl: url.origin, label };
      } catch (error) {
        notes.push(`${label}: ${error instanceof Error ? error.message : 'Could not resolve deployment'}`);
        return undefined;
      }
    }));
    for (const choice of resolved) {
      if (!choice) continue;
      const at = deployments.findIndex(d => d.deployment === choice.deployment);
      if (at < 0) deployments.push(choice);
      else deployments[at] = choice;
    }
    return { deployments, ...(notes.length ? { note: notes.join('\n') } : {}) };
  }

  async key(deployment: string, folder: string, renew = false): Promise<string> {
    if (convexDeploymentName(deployment) !== deployment) throw new Error(`"${deployment}" isn't a Convex deployment name.`);
    const file = path.join(this.dir, `${deployment}.json`);
    const saved = readSaved(file);
    if (saved && !renew) return saved.adminKey;
    const busy = this.pending.get(deployment);
    if (busy) return busy;
    const made = this.make(deployment, folder, file, saved?.name).finally(() => this.pending.delete(deployment));
    this.pending.set(deployment, made);
    return made;
  }

  private async make(deployment: string, folder: string, file: string, oldName: string | undefined): Promise<string> {
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(this.dir, 0o700);
    // A new key replaces one that stopped working (or was revoked): take
    // the old one off Convex too, if it's still there. Its failure is fine.
    // --no-install: the project's own convex package, never a download.
    if (oldName) await this.run(`npx --no-install convex deployment token delete ${oldName} --deployment ${deployment}`, folder);
    // Names are unique on a deployment, so each key gets its own; the host
    // says which Mac's runner made it, in the deployment's settings.
    const host = this.host.split('.')[0].toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '') || 'mac';
    const name = `threadbear-panel-${host}-${crypto.randomBytes(3).toString('hex')}`;
    // --save-env writes the key to a file rather than printing it, so it's
    // never in the command's output (which an error message quotes).
    const scratch = path.join(this.dir, `.new-${deployment}-${crypto.randomBytes(4).toString('hex')}.env`);
    const command = `npx --no-install convex deployment token create ${name} --deployment ${deployment} --save-env ${shellQuote(scratch)}`;
    try {
      const out = await this.run(command, folder);
      const adminKey = fs.existsSync(scratch) ? parseEnvValue(fs.readFileSync(scratch, 'utf8'), 'CONVEX_DEPLOY_KEY') : undefined;
      if (!out.ok || !adminKey) throw new Error(`Couldn't make a deploy key for ${deployment}: ${cliError(out.text)}`);
      fs.writeFileSync(file, JSON.stringify({ name, adminKey }) + '\n', { mode: 0o600 });
      fs.chmodSync(file, 0o600);
      return adminKey;
    } finally {
      fs.rmSync(scratch, { force: true });
    }
  }
}

// The Convex project folder a thread's panel for `deployment` comes from:
// the thread's own, or one of its projects' folders.
export function convexFolderFor(deployment: string, starts: string[], home: string): string | undefined {
  for (const start of starts) {
    const dir = findUp(start, home, isConvexProject);
    if (dir && convexDeploymentName(readEnvValue(dir, 'CONVEX_DEPLOYMENT')) === deployment) return dir;
  }
  return undefined;
}

function readSaved(file: string): { name: string; adminKey: string } | undefined {
  try {
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    return typeof saved?.name === 'string' && typeof saved?.adminKey === 'string' && saved.adminKey ? saved : undefined;
  } catch {
    return undefined;
  }
}

// The CLI's complaint, without its colours and spinners, short enough for
// the panel to show.
export function cliError(text: string): string {
  const lines = text
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
    .split('\n')
    .map((l) => l.replace(/^[\s✖✔⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏-]+/, '').trim())
    .filter(Boolean);
  const joined = lines.slice(-3).join(' ');
  return (joined || 'the Convex CLI gave no reason').slice(0, 400);
}

function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}
