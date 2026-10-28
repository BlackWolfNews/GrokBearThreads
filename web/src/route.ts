// Three pages, so no router: "/" is the list, "/t/<threadId>" a thread, and
// "/s/<slug>" a thread someone shared (no sign-in; share.tsx). Static
// hosting sends every unknown path to index.html, so a link works when
// opened cold.
import { useSyncExternalStore } from 'react';

export type Route = { page: 'list' } | { page: 'thread'; threadId: string } | { page: 'share'; slug: string };

function parse(): Route {
  const s = location.pathname.match(/^\/s\/([^/]+)\/?$/);
  if (s) return { page: 'share', slug: decodeURIComponent(s[1]) };
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
