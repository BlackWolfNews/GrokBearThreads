// How a thread's messages and tool lines are drawn, on Mike's own thread
// page (App.tsx) and on a shared one (share.tsx).

import Markdown, { defaultUrlTransform } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { go } from './route';
import { escapeDestinations, findStep, readLink } from './thread-links';

// A message or tool line, from phone:messages or share:view.
export type PageMessage = { seq: number; role: 'user' | 'assistant' | 'tool'; text: string; origin?: string; toolKind?: string; at: string };
type Group = { kind: 'message'; m: PageMessage } | { kind: 'tools'; items: PageMessage[] };

// Tool calls between two messages go together as one run.
export function groupTools(messages: PageMessage[]): Group[] {
  const out: Group[] = [];
  for (const m of messages) {
    const last = out.at(-1);
    if (m.role === 'tool') {
      if (last?.kind === 'tools') last.items.push(m);
      else out.push({ kind: 'tools', items: [m] });
    } else out.push({ kind: 'message', m });
  }
  return out;
}

function stepId(seq: number): string {
  return `step-${seq}`;
}

// Where a work: link goes: its step, out of any fold and lit up for a moment.
function showStep(seq: number) {
  const el = document.getElementById(stepId(seq));
  if (!el) return;
  const fold = el.closest('details');
  if (fold) fold.open = true;
  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  el.classList.add('lit');
  setTimeout(() => el.classList.remove('lit'), 2500);
}

// A run of tool calls: up to three shown as lines, more folded into "12 tool
// calls" that opens to the lines. What they printed stays on the Mac.
export function ToolRun({ items }: { items: PageMessage[] }) {
  const lines = (
    <ul className="tools">
      {items.map((m) => (
        <li key={m.seq} id={stepId(m.seq)} title={new Date(m.at).toLocaleString()}>
          <span className="tool-glyph" aria-hidden="true">
            {toolGlyph(m.toolKind)}
          </span>
          {m.text}
        </li>
      ))}
    </ul>
  );
  if (items.length <= 3) return <div className="tool-run">{lines}</div>;
  return (
    <details className="tool-run">
      <summary>{items.length} tool calls</summary>
      {lines}
    </details>
  );
}

function toolGlyph(kind?: string): string {
  switch (kind) {
    case 'command':
      return '›';
    case 'read':
      return '◦';
    case 'edit':
    case 'write':
      return '✎';
    case 'search':
    case 'web':
      return '⌕';
    default:
      return '·';
  }
}

// A shared thread's picture (share:view): `src` for one written in a
// message's Markdown, otherwise it goes after its row.
export type Picture = { seq: number; src?: string; url: string; width?: number; height?: number };

// A message's text as Markdown, its links opening in a new tab. A picture
// written as a path on Mike's Mac shows from `pictures` (src to URL) when
// it was uploaded for a shared thread, and as its alt text otherwise,
// rather than a broken image. A link into the thread goes to its step, or
// `threadPath` for another thread (Mike's own page only: whoever a thread's
// shared with can't open the others). With nowhere to go it's just its words.
export function MessageText({
  text,
  pictures,
  seq,
  rows,
  threadPath,
}: {
  text: string;
  pictures?: Map<string, string>;
  seq?: number;
  rows?: PageMessage[];
  threadPath?: (id: string) => string;
}) {
  return (
    <div className="md" id={seq === undefined ? undefined : stepId(seq)}>
      <Markdown
        remarkPlugins={[remarkGfm]}
        // The default keeps links safe (no javascript: and the like). A
        // file:// picture is let through only to be looked up in
        // `pictures`; it's never used as an address itself.
        // work:, thread: and review: are never used as addresses either: the
        // `a` below reads them and makes its own.
        urlTransform={(url, key) => ((key === 'src' && url.startsWith('file://')) || (key === 'href' && readLink(url)) ? url : defaultUrlTransform(url))}
        components={{
          a: ({ node: _, href, children, ...p }) => {
            const link = href ? readLink(href) : undefined;
            if (!link) {
              return (
                <a {...p} href={href} target="_blank" rel="noreferrer">
                  {children}
                </a>
              );
            }
            if (link.kind === 'step' && seq !== undefined && rows) {
              const step = findStep(link.quote, seq, rows);
              if (step !== undefined) {
                return (
                  <a
                    href={`#${stepId(step)}`}
                    onClick={(e) => {
                      e.preventDefault();
                      showStep(step);
                    }}
                  >
                    {children}
                  </a>
                );
              }
            }
            if (link.kind === 'thread' && threadPath) {
              const path = threadPath(link.id);
              return (
                <a
                  href={path}
                  onClick={(e) => {
                    if (e.metaKey || e.ctrlKey) return;
                    e.preventDefault();
                    go(path);
                  }}
                >
                  {children}
                </a>
              );
            }
            return <>{children}</>;
          },
          img: ({ src, alt }) => {
            const s = typeof src === 'string' ? src : '';
            const url = pictures?.get(s) ?? (/^https?:\/\//.test(s) ? s : undefined);
            if (!url) return <span className="muted">[{alt || 'image'}]</span>;
            return (
              <a href={url} target="_blank" rel="noreferrer">
                <img className="picture" src={url} alt={alt ?? ''} loading="lazy" referrerPolicy="no-referrer" />
              </a>
            );
          },
        }}
      >
        {escapeDestinations(text)}
      </Markdown>
    </div>
  );
}

// Pictures that go after a row: an attachment, or what a tool handed back.
export function Pictures({ items }: { items: Picture[] }) {
  if (!items.length) return null;
  return (
    <div className="pictures">
      {items.map((p) => (
        <a key={p.url} href={p.url} target="_blank" rel="noreferrer">
          <img className="picture" src={p.url} alt="" loading="lazy" width={p.width} height={p.height} />
        </a>
      ))}
    </div>
  );
}

// Which row each picture without a src goes after: the one with the
// greatest seq at or before its own (rows are oldest first).
export function picturesByRow(rows: { seq: number }[], pictures: Picture[]): Map<number, Picture[]> {
  const out = new Map<number, Picture[]>();
  for (const p of pictures) {
    if (p.src) continue;
    let at: number | undefined;
    for (const r of rows) {
      if (r.seq > p.seq) break;
      at = r.seq;
    }
    if (at === undefined) continue;
    out.set(at, [...(out.get(at) ?? []), p]);
  }
  return out;
}
