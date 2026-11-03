// Small words for the pages: model names, dates, times since.

// "claude-opus-5-5" → "Claude Opus 5.5", "opus" → "Claude Opus",
// "gpt-6-astra" → "GPT-6 Astra". With no model, the CLI's name.
export function modelLabel(provider?: string, model?: string): string {
  const cli = provider === 'codex' ? 'Codex' : 'Claude';
  if (!model) return cli;
  const id = model.replace(/\[.*\]$/, '');
  const claude = id.match(/^(?:claude-)?(opus|sonnet|haiku|fable)(?:-(\d+)(?:-(\d+))?)?/i);
  if (claude) {
    const family = claude[1]![0]!.toUpperCase() + claude[1]!.slice(1).toLowerCase();
    const version = claude[2] ? ` ${claude[2]}${claude[3] ? `.${claude[3]}` : ''}` : '';
    return `Claude ${family}${version}`;
  }
  const gpt = id.match(/^gpt-([\d.]+)(?:-(.+))?$/i);
  if (gpt) return `GPT-${gpt[1]}${gpt[2] ? ` ${gpt[2].split('-').map(cap).join(' ')}` : ''}`;
  return id;
}

function cap(w: string): string {
  return w ? w[0]!.toUpperCase() + w.slice(1) : w;
}

// "3 Nov 2026"
export function day(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

// "now", "5m", "3h", "2d", then the date.
export function ago(ms: number): string {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)}d`;
  return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

// The preview is the reply's first lines as Markdown; lists show it as
// plain text.
export function plain(md: string): string {
  return md
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^\s*#{1,6}\s+|^\s*>\s*/gm, '')
    .replace(/\*\*|__|`/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// The last part of a folder's path: "acme-web".
export function folderName(path: string): string {
  return path.replace(/\/+$/, '').split('/').pop() || path;
}

// Markdown as one line of plain text for a link preview, as convex/share.ts
// plainText makes it: each line or list item ends in a full stop.
export function sentences(md: string): string {
  const lines = md
    .replace(/```[\s\S]*?```/g, '\n')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\*\*|__|`/g, '')
    .split('\n')
    .map((l) => l.replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)/, '').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  return lines.map((l, i) => (i < lines.length - 1 && !/[.!?:…]$/.test(l) ? `${l}.` : l)).join(' ');
}
