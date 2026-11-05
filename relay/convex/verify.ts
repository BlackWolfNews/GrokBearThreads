// How /register (http.ts) tells a real Threadbear backend from someone
// scripting it. Plain TypeScript with no Convex imports, so the runner's
// unit tests can check it.
//
// Every caller used to share one allowance of new installs a day, so one
// script could use it up and lock out every new backend. A backend from
// 5 Nov 2026 names its own deployment and a nonce, and the relay posts
// the nonce back to that deployment's /relay/verify (convex/http.ts),
// which only says yes to a nonce it made itself. That proves the caller
// runs the deployment, so it gets one install per deployment and no shared
// allowance to use up. Callers can't be told apart by address instead:
// every backend calls from Convex's own servers. There's no unchecked way
// in any more (http.ts says why).

// A Convex cloud deployment's HTTP address, `https://<name>.convex.site`
// or `https://<name>.<region>.convex.site`, as its CONVEX_SITE_URL says
// it. Anything else (a self-hosted backend, a custom domain) is null and
// can't register: the relay only ever calls back to Convex's own hosts,
// so it can't be pointed at anything else. Self-hosting? Run your own
// relay (docs/push-relay.md).
export function convexSite(raw: string | undefined): string | null {
  if (!raw) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.port || u.username || u.password || u.search || u.hash || (u.pathname !== '/' && u.pathname !== '')) return null;
  if (!/^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)?\.convex\.site$/.test(u.hostname)) return null;
  return `https://${u.hostname}`;
}

export const VERIFY_TIMEOUT_MS = 5_000;

// Whether the deployment says the nonce is its own: a 200 with
// `{ ok: true }` from its /relay/verify. A timeout, an error or any other
// answer is a no.
export async function deploymentVouches(site: string, nonce: string, fetcher: typeof fetch = fetch): Promise<boolean> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), VERIFY_TIMEOUT_MS);
  try {
    const res = await fetcher(`${site}/relay/verify`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ nonce }), signal: abort.signal });
    if (res.status !== 200) return false;
    const b = (await res.json().catch(() => null)) as { ok?: unknown } | null;
    return b?.ok === true;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}
