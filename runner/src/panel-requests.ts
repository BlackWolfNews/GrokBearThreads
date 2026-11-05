// The show_panel tool's side of "Showing panels" (docs/protocol.md): which
// names an agent can give, and how long the tool waits to hear the app
// showed one. The request itself lives on the thread record (Runner).
import type { Panel, PanelPlace } from './protocol.ts';

export const PANEL_PLACES: readonly PanelPlace[] = ['tab', 'left', 'right', 'top', 'bottom', 'window'];

// How long show_panel waits for threads.panelShown. The app answers within
// a moment when Mike is on the thread, so anything longer means he isn't.
export const PANEL_ACK_WAIT_MS = 2000;

// The app's own panels, by the names the tool takes. Patches only counts
// for a thread that has patches; the rest every thread has.
const THREAD_PANELS = [
  { id: 'highlights', title: 'Highlights' },
  { id: 'patches', title: 'Patches' },
  { id: 'browser', title: 'Browser' },
];
const APP_PANELS = [
  { id: 'usage', title: 'Usage' },
  { id: 'updates', title: 'Updates' },
  { id: 'connectors', title: 'Connectors' },
];

// A panel name as the agent gave it, as the panel it means. Throws with
// what the thread has when it's none of them, so the agent can pick again.
export function resolvePanel(name: string, has: { panels: Panel[]; hasPatches: boolean }): { id: string; title: string } {
  const raw = name.trim().toLowerCase();
  const wanted = raw === 'threadbear.browser' ? 'browser' : raw;
  if (!wanted) throw new Error('Name a panel: highlights, patches, usage, updates, connectors, or one of the thread\'s own.');
  const own = THREAD_PANELS.filter((p) => p.id !== 'patches' || has.hasPatches);
  const builtIn = [...own, ...APP_PANELS].find((p) => p.id === wanted);
  if (builtIn) return builtIn.id === 'browser' ? { id: 'threadbear.browser', title: 'Browser' } : builtIn;
  // A patch's panel, by its id ("convex.dashboard") or its tab's title.
  const hit = has.panels.find((p) => p.id.toLowerCase() === wanted) ?? has.panels.find((p) => p.title.toLowerCase() === wanted);
  if (hit) return { id: hit.id, title: hit.title };
  const names = [...own.map((p) => p.id), ...has.panels.map((p) => `${p.id} (${p.title})`), ...APP_PANELS.map((p) => p.id)];
  throw new Error(`No panel called ${name.trim()}. This thread has ${names.slice(0, -1).join(', ')} and ${names.at(-1)}.`);
}
