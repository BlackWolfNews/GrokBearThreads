// The part of inbox.tsx with no Convex in it, so it can be tested alone.
export type InboxRow = { threadId: string; view: string; lastActivityMs: number };
export type Changes<R extends InboxRow> = { rows: (R & { updatedMs: number })[]; gone: string[] };

// Rows are stamped by the mutation that wrote them, which can commit a moment
// after one stamped later, so asking from exactly the newest could miss it.
// Asking a little further back only re-reads a row or two.
export const CHANGES_MARGIN_MS = 5000;

export function firstSince(at: number): number {
  return at - CHANGES_MARGIN_MS;
}

export function sortInbox<R extends InboxRow>(rows: Iterable<R>): R[] {
  return [...rows].sort((a, b) => b.lastActivityMs - a.lastActivityMs);
}

// Brings an answer into the list, and says where to ask from next: the same
// place until something newer has been heard, so a re-run with nothing new
// doesn't start another subscription.
export function mergeChanges<R extends InboxRow>(have: R[], since: number, changes: Changes<R>): { rows: R[]; since: number } {
  const byId = new Map(have.map((r) => [r.threadId, r]));
  let next = since;
  for (const { updatedMs, ...r } of changes.rows) {
    if (r.view === 'inbox') byId.set(r.threadId, r as unknown as R);
    else byId.delete(r.threadId);
    next = Math.max(next, updatedMs - CHANGES_MARGIN_MS);
  }
  for (const id of changes.gone) byId.delete(id);
  return { rows: sortInbox(byId.values()), since: next };
}
