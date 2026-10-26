import fs from 'node:fs';
import path from 'node:path';
import type { Account } from './protocol.ts';
import type { Config } from './config.ts';
import { isDirectory } from './fsutil.ts';

// Reads only oauthAccount.emailAddress from a .claude.json. Tokens live in
// the Keychain and are never read; this file only names the login.
export function readLoginEmail(claudeJsonPath: string): string | undefined {
  try {
    const raw = fs.readFileSync(claudeJsonPath, 'utf8');
    const parsed = JSON.parse(raw) as { oauthAccount?: { emailAddress?: unknown } };
    const email = parsed.oauthAccount?.emailAddress;
    return typeof email === 'string' && email ? email : undefined;
  } catch {
    return undefined;
  }
}

// Claude logins: ~/.claude is claude-main (its .claude.json sits at
// ~/.claude.json), and each Token Stats account folder claude-N is its own
// CLAUDE_CONFIG_DIR with .claude.json inside.
export function discoverAccounts(cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>): Account[] {
  const out: Account[] = [];
  if (isDirectory(cfg.claudeMainDir)) {
    out.push({
      id: 'claude-main',
      provider: 'claude',
      title: readLoginEmail(cfg.claudeMainJson) ?? readLoginEmail(path.join(cfg.claudeMainDir, '.claude.json')) ?? 'claude-main',
      configDir: cfg.claudeMainDir,
    });
  }
  let names: string[] = [];
  try {
    names = fs.readdirSync(cfg.tokenStatsAccountsDir);
  } catch {
    names = [];
  }
  const numbered = names
    .map((n) => /^claude-(\d+)$/.exec(n))
    .filter((m): m is RegExpExecArray => m !== null)
    .sort((a, b) => Number(a[1]) - Number(b[1]));
  for (const m of numbered) {
    const dir = path.join(cfg.tokenStatsAccountsDir, m[0]);
    if (!isDirectory(dir)) continue;
    out.push({
      id: m[0],
      provider: 'claude',
      title: readLoginEmail(path.join(dir, '.claude.json')) ?? m[0],
      configDir: dir,
    });
  }
  return out;
}

export class AccountRegistry {
  private cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>;
  private cache: Account[] = [];
  private at = 0;

  constructor(cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>) {
    this.cfg = cfg;
  }

  // Re-scans at most every 10 seconds so a newly added login shows up
  // without restarting the runner.
  list(): Account[] {
    if (Date.now() - this.at > 10_000 || this.cache.length === 0) {
      this.cache = discoverAccounts(this.cfg);
      this.at = Date.now();
    }
    return this.cache;
  }

  get(id: string): Account | undefined {
    return this.list().find((a) => a.id === id);
  }
}
