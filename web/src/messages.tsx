// How a thread's messages and tool lines are drawn, on Mike's own thread
// page (App.tsx) and on a shared one (share.tsx).

import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

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

// A run of tool calls: up to three shown as lines, more folded into "12 tool
// calls" that opens to the lines. What they printed stays on the Mac.
export function ToolRun({ items }: { items: PageMessage[] }) {
  const lines = (
    <ul className="tools">
      {items.map((m) => (
        <li key={m.seq} title={new Date(m.at).toLocaleString()}>
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

// A message's text as Markdown, its links opening in a new tab.
export function MessageText({ text }: { text: string }) {
  return (
    <div className="md">
      <Markdown remarkPlugins={[remarkGfm]} components={{ a: (p) => <a {...p} target="_blank" rel="noreferrer" /> }}>
        {text}
      </Markdown>
    </div>
  );
}
