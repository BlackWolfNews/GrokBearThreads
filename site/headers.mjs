// The headers every response gets, shared by the Worker (worker.mjs) and the local server
// (scripts/serve.mjs), so what you see locally is what prod sends. Copied from Quick Ask's site.

/**
 * The page only loads its own files: one script (src/site.js, the menu and the scroll reveals),
 * its stylesheet, the fonts and the images. Cloudflare's Web Analytics beacon is allowed in case
 * Cloudflare injects it, like it can on mikecann.app. JSON-LD blocks aren't run as scripts.
 */
const CSP = [
  "default-src 'none'",
  "script-src 'self' https://static.cloudflareinsights.com",
  "connect-src 'self'",
  "font-src 'self'",
  "style-src 'self'",
  "img-src 'self'",
  "manifest-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");

/** styles.1a2b3c4d.css and site.1a2b3c4d.js: the build puts a hash of the contents in the name. */
const HASHED = /\.[0-9a-f]{8}\.(css|js)$/;

/** Headers to set on a response for `pathname` with this Content-Type. */
export function headersFor(pathname, contentType = "") {
  const headers = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "strict-origin-when-cross-origin" };
  if (contentType.startsWith("text/html")) {
    // Pages can change any time, so browsers check back every five minutes.
    headers["Cache-Control"] = "public, max-age=300";
    headers["Content-Security-Policy"] = CSP;
  } else if (HASHED.test(pathname)) {
    // A changed file gets a new name, so the old one can be kept for a year.
    headers["Cache-Control"] = "public, max-age=31536000, immutable";
  } else {
    // Screenshots, icons, the OG image, robots.txt and the sitemap keep their names, so a day.
    headers["Cache-Control"] = "public, max-age=86400";
  }
  return headers;
}
