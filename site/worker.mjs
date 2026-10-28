// threadbear.mikecann.app: the built site in site/dist, served with Workers static assets. The
// Worker runs first for every request (run_worker_first in wrangler.jsonc), so the 405s and
// the security and cache headers in headers.mjs apply to every file and to the 404 page.
// Static assets do the rest: / serves index.html, and anything that isn't there gets 404.html
// with a 404. Copied from Quick Ask's site.
import { headersFor } from "./headers.mjs";

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    const extra = headersFor(new URL(request.url).pathname, headers.get("Content-Type") ?? "");
    for (const [name, value] of Object.entries(extra)) headers.set(name, value);
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  },
};
