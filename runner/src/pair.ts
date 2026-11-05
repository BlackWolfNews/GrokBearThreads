// `tb pair`: what to copy from this Mac to another so that Mac's app can
// open this runner's threads (docs/protocol.md, "Other runners' threads").
// Two files: this runner's token, and the host to send it to. The app on the
// other Mac takes the host only from here, never from the backend's mirror,
// which any runner with the shared key can rewrite. It prints the token's
// path, not the token, so an agent running it doesn't get the secret.
import os from 'node:os';
import { paths, type Config } from './config.ts';
import { shQuote } from './tb-dev.ts';

export function pairText(cfg: Pick<Config, 'home' | 'sync'>, user = os.userInfo().username): { ok: boolean; text: string } {
  const id = cfg.sync.runnerId;
  if (!id) return { ok: false, text: "This runner has no id yet (sync.runnerId in runner.json): it gets one the first time it syncs. Start it with sync on, then run tb pair again." };
  let host: string | undefined;
  try {
    host = cfg.sync.rpcUrl ? new URL(cfg.sync.rpcUrl).hostname.toLowerCase().replace(/\.+$/, '') : undefined;
  } catch {
    host = undefined;
  }
  if (!host) return { ok: false, text: "sync.rpcUrl in runner.json isn't set (or isn't a URL), so another Mac can't reach this one. Set it to this Mac's wss://<tailnet name>:<port>/rpc first." };
  const token = paths.token(cfg.home);
  const name = cfg.sync.name ? `${cfg.sync.name} (${id})` : id;
  const text = [
    `${name} is at ${host}.`,
    'To open its threads from another Mac, put two owner-only files in secrets/runners/',
    "in that Mac's Threadbear data folder (~/Library/Application Support/Threadbear):",
    '',
    `  ${id}.token  a copy of ${token}`,
    `  ${id}.host   this one line: ${host}`,
    '',
    "That Mac's app sends the token only to that host. For example, on that Mac:",
    '',
    `  d="$HOME/Library/Application Support/Threadbear/secrets/runners"; mkdir -p "$d"`,
    `  scp ${shQuote(`${user}@${host}:${token}`)} "$d/${id}.token"`,
    `  printf '%s\\n' ${host} > "$d/${id}.host"`,
    `  chmod 600 "$d/${id}.token" "$d/${id}.host"`,
  ].join('\n');
  return { ok: true, text };
}

export function pairCommand(cfg: Pick<Config, 'home' | 'sync'>): number {
  const r = pairText(cfg);
  (r.ok ? console.log : console.error)(r.text);
  return r.ok ? 0 : 1;
}
