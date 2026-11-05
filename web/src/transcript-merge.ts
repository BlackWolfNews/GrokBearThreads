// The part of transcript.ts with no Convex in it, so it can be tested alone.
export type HeldRow = { seq: number };
export type Held<R extends HeldRow> = { rows: Map<number, R>; hasMore: boolean };
export type PageLike<R extends HeldRow> = { messages: R[]; hasMore: boolean };

// Brings the tail's answer into what's held. Rows that have scrolled out of
// the tail stay. A tail that starts after everything held means more arrived
// than it covers (the page was away, the connection dropped): what's held
// goes, and older rows are read again as the thread opening would.
export function mergeTail<R extends HeldRow>(held: Held<R> | undefined, tail: PageLike<R>): { held: Held<R>; gap: boolean } {
  const first = tail.messages[0]?.seq;
  const newest = held && held.rows.size ? Math.max(...held.rows.keys()) : undefined;
  const gap = Boolean(tail.hasMore && first !== undefined && newest !== undefined && first > newest);
  const rows = new Map(gap ? [] : (held?.rows ?? []));
  for (const m of tail.messages) rows.set(m.seq, m);
  // With nothing held, what's above is whatever the tail says: an empty first
  // answer's "no more" says nothing about the rows that have arrived since.
  return { held: { rows, hasMore: newest !== undefined && !gap ? held!.hasMore : tail.hasMore }, gap };
}

export function mergeOlder<R extends HeldRow>(held: Held<R>, page: PageLike<R>): Held<R> {
  const rows = new Map(held.rows);
  for (const m of page.messages) rows.set(m.seq, m);
  return { rows, hasMore: page.hasMore };
}
