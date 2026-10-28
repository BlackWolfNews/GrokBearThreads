// The browser's token is a phone token (convex/tokens.ts) named "web-…".
// It lives in localStorage and goes with every query and mutation, exactly
// as the iPhone app's does.
import { useSyncExternalStore } from 'react';

const KEY = 'threadbear.token';
const listeners = new Set<() => void>();

export function takeTokenFromHash(): void {
  const params = new URLSearchParams(location.hash.slice(1));
  const token = params.get('token');
  if (!token) return;
  localStorage.setItem(KEY, token);
  history.replaceState(null, '', location.pathname + location.search);
}

export function signOut(): void {
  localStorage.removeItem(KEY);
  listeners.forEach((l) => l());
}

export function useToken(): string | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      window.addEventListener('storage', l);
      return () => {
        listeners.delete(l);
        window.removeEventListener('storage', l);
      };
    },
    () => localStorage.getItem(KEY),
  );
}
