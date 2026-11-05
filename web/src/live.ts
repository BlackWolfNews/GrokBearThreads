// Live queries that let go while nobody can see them. A browser tab left open
// behind others otherwise re-runs phone:threads (about 40 KB for Mike's inbox)
// on every thread row written, all day. A quick look at another tab keeps
// them; coming back after longer reads once and carries on, with what was on
// screen staying there meanwhile.
import { useEffect, useRef, useState } from 'react';
import { useQuery } from 'convex/react';
import type { FunctionReference, FunctionReturnType } from 'convex/server';

const AWAY_AFTER_MS = 60_000;

export function usePageAway(): boolean {
  const [away, setAway] = useState(false);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const changed = () => {
      clearTimeout(timer);
      if (document.hidden) timer = setTimeout(() => setAway(true), AWAY_AFTER_MS);
      else setAway(false);
    };
    changed();
    document.addEventListener('visibilitychange', changed);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', changed);
    };
  }, []);
  return away;
}

// As useQuery, but gives the last answer while the page is away. 'skip' is
// for a query nothing wants right now, and gives undefined as useQuery does.
export function useLiveQuery<Q extends FunctionReference<'query'>>(query: Q, args: Q['_args'] | 'skip'): FunctionReturnType<Q> | undefined {
  const away = usePageAway();
  const value = useQuery(query, (away || args === 'skip' ? 'skip' : args) as never) as FunctionReturnType<Q> | undefined;
  const last = useRef<{ key: string; value: FunctionReturnType<Q> | undefined }>({ key: '', value: undefined });
  const key = args === 'skip' ? '' : JSON.stringify(args);
  if (value !== undefined) last.current = { key, value };
  if (args === 'skip') return undefined;
  // Also while it subscribes again on coming back, so nothing flashes "Loading".
  return value ?? (last.current.key === key ? last.current.value : undefined);
}
