import type { ThreadStartedBy } from './protocol.ts';

// Who `tb new` says started the thread. A thread's own agent running it is
// an agent, whatever it says; --from names a tool (a poller has no thread).
// Neither: nothing, as it could be Mike at a terminal.
export function startedByFlags(f: { from?: unknown; why?: unknown; icon?: unknown }, threadId?: string): ThreadStartedBy | undefined {
  const why: { why?: string } = f.why ? { why: String(f.why) } : {};
  if (f.from) return { kind: 'tool', label: String(f.from), ...(f.icon ? { icon: String(f.icon) } : {}), ...why, ...(threadId ? { threadId } : {}) };
  if (threadId) return { kind: 'thread', label: 'Agent', threadId, ...why };
  return f.why ? { kind: 'tool', label: 'A script', ...why } : undefined;
}
