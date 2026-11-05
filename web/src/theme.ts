// Appearance on this browser: the system's, or always light or dark. Applied
// before the first render (main.tsx), so a page never flashes the other one.
export type Theme = 'system' | 'light' | 'dark';
const KEY = 'threadbear.theme';

export function readTheme(): Theme {
  const saved = localStorage.getItem(KEY);
  return saved === 'light' || saved === 'dark' ? saved : 'system';
}

export function applyTheme(theme: Theme = readTheme()): void {
  if (theme === 'system') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
}

export function setTheme(theme: Theme): void {
  localStorage.setItem(KEY, theme);
  applyTheme(theme);
}
