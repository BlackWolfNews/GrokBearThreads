#!/usr/bin/env node
// Serves site/dist on http://localhost:5176 the way prod does (worker.mjs and wrangler.jsonc):
// anything that isn't a file gets 404.html with a 404, only GET and HEAD are allowed, and every
// response gets the same headers as prod (headers.mjs). `npm run serve`. Copied from Quick Ask's.
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { headersFor } from "../headers.mjs";

const dist = fileURLToPath(new URL("../dist/", import.meta.url));
const port = Number(process.env.PORT ?? 5176);
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".svg": "image/svg+xml", ".xml": "application/xml",
  ".txt": "text/plain; charset=utf-8", ".webmanifest": "application/manifest+json", ".mp4": "video/mp4" };

const isFile = (file) => file.startsWith(dist) && existsSync(file) && statSync(file).isFile();

function send(req, res, status, file, pathname) {
  const type = types[extname(file)] ?? "application/octet-stream";
  const size = statSync(file).size;
  // Byte ranges, as Cloudflare serves them: Safari won't play a video without them.
  const range = status === 200 && /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
  if (range) {
    const start = range[1] ? Number(range[1]) : size - Number(range[2]);
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    res.writeHead(206, { "Content-Type": type, "Content-Range": `bytes ${start}-${end}/${size}`, "Content-Length": end - start + 1,
      "Accept-Ranges": "bytes", ...headersFor(pathname, type) });
    if (req.method === "HEAD") return res.end();
    return createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(status, { "Content-Type": type, "Content-Length": size, "Accept-Ranges": "bytes", ...headersFor(pathname, type) });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

createServer((req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD" }).end("Method not allowed");
    return;
  }
  const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname);
  // Like Cloudflare's html_handling: the .html address redirects to the one without it.
  if (pathname.endsWith(".html")) {
    const clean = pathname === "/index.html" ? "/" : pathname.slice(0, -5);
    res.writeHead(307, { Location: clean }).end();
    return;
  }
  const file = normalize(join(dist, pathname === "/" ? "index.html" : pathname));
  if (isFile(file)) return send(req, res, 200, file, pathname);
  if (isFile(`${file}.html`)) return send(req, res, 200, `${file}.html`, pathname);
  send(req, res, 404, join(dist, "404.html"), pathname);
}).listen(port, () => console.log(`http://localhost:${port}`));
