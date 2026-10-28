// Two pages, so no router: "/" is the list and "/t/<threadId>" a thread.
// Static hosting sends every unknown path to index.html, so a thread link
// works when opened cold.
import { useSyncExternalStore } from 'react';

export type Route = { page: 'list' } | { page: 'thread'; threadId: string };

function parse(): Route {
  const m = location.pathname.match(/^\/t\/([^/]+)\/?$/);
  return m ? { page: 'thread', threadId: decodeURIComponent(m[1]) } : { page: 'list' };
}

let current = parse();
const listeners = new Set<() => void>();
window.addEventListener('popstate', () => {
  current = parse();
  listeners.forEach((l) => l());
});

export function go(path: string): void {
  if (path === location.pathname) return;
  history.pushState(null, '', path);
  current = parse();
  listeners.forEach((l) => l());
  window.scrollTo(0, 0);
}

export function useRoute(): Route {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => current,
  );
}

export function threadPath(threadId: string): string {
  return `/t/${encodeURIComponent(threadId)}`;
}
