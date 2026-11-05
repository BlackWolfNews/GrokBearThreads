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
    // Static assets answer a Range request with the whole file, and Safari on an iPhone won't
    // play a <video> without byte ranges. The hero's clips are a few hundred KB, so cut the
    // range out here.
    const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("Range") ?? "");
    if (headers.get("Content-Type")?.startsWith("video/")) headers.set("Accept-Ranges", "bytes");
    if (range && response.status === 200 && headers.get("Content-Type")?.startsWith("video/")) {
      const body = await response.arrayBuffer();
      const size = body.byteLength;
      const start = range[1] ? Number(range[1]) : Math.max(0, size - Number(range[2]));
      const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
      if (start >= size || start > end) {
        return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
      }
      headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
      headers.set("Content-Length", String(end - start + 1));
      return new Response(request.method === "HEAD" ? null : body.slice(start, end + 1), { status: 206, headers });
    }
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  },
};
