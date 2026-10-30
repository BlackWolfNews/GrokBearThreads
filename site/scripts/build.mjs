#!/usr/bin/env node
// Builds the landing page (threadbear.mikecann.app) into site/dist for the Cloudflare Worker in
// worker.mjs: src's pages wrapped in src/layout.html, with public/ copied alongside. No bundler
// and no dependencies, a copy of Quick Ask's web build (~/dev/me/quick-ask/scripts/build-web.mjs)
// cut down to one page and a 404. `npm run build`, then `npm run serve` to look at it on :5176.
//
// Pages can use {{mac <name> [classes]}} for a Mac app screenshot, {{phone <name> [hero] [classes]}}
// for an iPhone one, {{icon <name>}} for a Phosphor icon, {{fork}} and {{appStoreBadge}} for the
// two ways to get it, and {{commits}} / {{firstDay}} for the repo's own numbers.
//
// The docs pages (/docs and /docs/<slug>) aren't in src: scripts/docs.mjs makes them from the
// repo's docs/guide.md, a page per `## ` section, in the same layout.
//
// It won't build if an em or en dash gets into a page, a {{placeholder}} is left over, a style=""
// slips in (the CSP blocks it), or a link or image points at a file or #anchor that isn't there.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { APP_STORE_LIVE, APP_STORE_URL, GITHUB_PUBLIC, GITHUB_URL, SITE_URL } from "../site.mjs";
import { markdown, readGuide, summary } from "./docs.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "src");
const dist = join(root, "dist");

if (APP_STORE_LIVE && !/^https:\/\/apps\.apple\.com\/app\/id\d+$/.test(APP_STORE_URL)) {
  throw new Error("APP_STORE_LIVE is on, so site.mjs needs APP_STORE_URL (https://apps.apple.com/app/id<Apple ID>)");
}

/**
 * The repo's own numbers for the proof line, read from git at build time so they never go stale:
 * how many commits main has, and the day of the first one. Built from a shallow clone they'd be
 * wrong, so that refuses to build.
 */
function git(...args) {
  return execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
}
if (git("rev-parse", "--is-shallow-repository") === "true") throw new Error("Build from a full clone: the proof line counts commits");
const commits = Number(git("rev-list", "--count", "HEAD"));
const firstDay = new Date(git("log", "--reverse", "--format=%aI").split("\n")[0])
  .toLocaleDateString("en-AU", { day: "numeric", month: "long", year: "numeric", timeZone: "Australia/Perth" });

/**
 * The screenshots. Mac ones are the app's design screenshots (app/Tools/screenshots.sh, the mock
 * runner's demo threads), iPhone ones the FakeBackend's sample threads (ios/scripts/sim-shots.sh).
 * scripts/images.mjs makes the WebPs. Nothing here is from a real thread.
 */
const MAC = {
  "mac-thread": {
    size: 'width="2200" height="1454"',
    alt: "The Threadbear Mac app. On the left, the inbox: threads with a project tile each, some marked Needs you, and two running at the bottom. In the middle, a thread about making uploads resume after a crash, with a bar chart, the agent's reply and a card asking to run rm -rf .build DerivedData with Allow, Always allow and Deny. On the right, the thread's highlights: a file it wrote, a link and three files changed.",
  },
  "mac-patches": {
    size: 'width="940" height="630"',
    alt: "Part of a Threadbear thread while the agent is still writing, with Bear with me and 8 seconds so far under the reply, and a row of buttons from the project's patches above the message box: Typecheck, Open logs and Deploy to prod.",
  },
  "mac-accounts": {
    size: 'width="700" height="576"',
    alt: "The account menu in Threadbear, listing four Claude logins and a Codex one, each with how much of its five hour and weekly limits is left.",
  },
  "mac-diffs": {
    size: 'width="940" height="985"',
    alt: "Part of a finished turn in Threadbear: a plan with all three steps ticked off, Edited 2 files, ran a command, a short list of what changed and a before and after table for an upload that gets cut off.",
  },
};
const PHONE = {
  inbox: "Threadbear on iPhone: the inbox, with Release 1.2 of the garden app marked Needs OK, a question about where settings should live marked Asking, two finished threads and one running.",
  approval: "A thread on iPhone asking to run git tag v1.2.0 and push it, with Allow, Always and Deny buttons and a reply box at the bottom.",
  question: "A thread on iPhone asking where each person's settings should live, in the database or on the phone, with a box for something else and a Send answer button.",
};

/** A Mac screenshot, its own window shape (transparent corners), so no frame drawn round it. */
function mac(name, ...flags) {
  const shot = MAC[name];
  if (!shot) throw new Error(`No Mac screenshot called ${name}`);
  const hero = flags.includes("hero");
  const extra = flags.filter((f) => f !== "hero");
  return `<img class="mac${extra.map((c) => ` ${c}`).join("")}" src="/screens/${name}.webp" alt="${escape(shot.alt)}" ${shot.size} ${hero ? 'loading="eager" fetchpriority="high"' : 'loading="lazy"'} decoding="async">`;
}

/** An iPhone screenshot in a drawn phone, like Quick Ask's. */
function phone(name, ...flags) {
  const alt = PHONE[name];
  if (!alt) throw new Error(`No iPhone screenshot called ${name}`);
  const extra = flags.filter((f) => f !== "hero");
  const loading = flags.includes("hero") ? 'loading="eager"' : 'loading="lazy"';
  return `<div class="phone${extra.map((c) => ` ${c}`).join("")}"><img src="/screens/phone-${name}.webp" alt="${escape(alt)}" width="600" height="1304" ${loading} decoding="async"></div>`;
}

const APPLE_LOGO = `<svg class="appstore-logo" viewBox="0 0 24 24" aria-hidden="true"><path d="M16.37 12.6c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.7-3.18-1.73-1.35-.14-2.65.8-3.33.8-.7 0-1.75-.78-2.88-.76-1.48.02-2.85.86-3.61 2.19-1.55 2.68-.4 6.63 1.1 8.8.74 1.06 1.61 2.25 2.75 2.2 1.11-.04 1.52-.71 2.86-.71 1.33 0 1.71.71 2.87.69 1.19-.02 1.94-1.07 2.66-2.14.85-1.23 1.19-2.43 1.21-2.49-.03-.01-2.31-.89-2.33-3.54ZM14.2 6.17c.6-.74 1.01-1.75.9-2.77-.87.04-1.94.59-2.56 1.32-.56.64-1.05 1.69-.92 2.68.97.08 1.97-.49 2.58-1.23Z"/></svg>`;

/** The black App Store badge, drawn rather than hotlinked. Until the app's out it isn't a link. */
function appStoreBadge() {
  const label = `${APPLE_LOGO}<span><small>${APP_STORE_LIVE ? "Download on the" : "Coming soon to the"}</small><b>App Store</b></span>`;
  return APP_STORE_LIVE ? `<a class="appstore" href="${APP_STORE_URL}">${label}</a>` : `<span class="appstore soon">${label}</span>`;
}

/**
 * The main button: fork the code on GitHub. While the repo's private it's visibly not a button
 * (the skill's B9: no dead links), with "coming soon" on it.
 */
function fork() {
  const label = `${icon("github-logo")}<span>Fork it on GitHub</span>`;
  return GITHUB_PUBLIC
    ? `<a class="btn btn-lg" href="${GITHUB_URL}">${label}</a>`
    : `<span class="btn btn-lg soon" aria-disabled="true">${label}<small>Coming soon</small></span>`;
}

/** The corner triangle with the octocat, like Walkies' and Poddle's, once the repo's public. */
function githubCorner() {
  if (!GITHUB_PUBLIC) return "";
  return `<a class="corner github" href="${GITHUB_URL}" target="_blank" rel="noopener noreferrer" aria-label="View the Threadbear code on GitHub" title="View the code on GitHub">
    <svg viewBox="0 0 250 250" aria-hidden="true">
      <path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z"/>
      <path class="octo arm" d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2"/>
      <path class="octo" d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z"/>
    </svg>
  </a>`;
}

/**
 * The FAQ, as plain questions and answers (on the page for answer engines, and as FAQPage
 * structured data). Answers can hold links and <code>; the structured data gets plain text.
 * Anything here that isn't built yet has a NOT BUILT note beside it, like the page.
 */
const FAQ = [
  // NOT BUILT: the installer that makes your Convex deployment. The free plan line is a guess
  // from what the mirror sends (docs/convex-backend.md, "A for now"), not measured for anyone
  // but Mike.
  ["What does it cost?",
    "Threadbear is free. You need Claude Code or Codex, so a Claude or ChatGPT plan, which you're probably paying for already, and a Convex account for your deployment. Convex has a free plan and Threadbear only puts the small stuff up there, so I'd expect most people to fit in it."],
  ["Which Macs does it run on?",
    "Macs with Apple silicon, on macOS 26 or later. There's no Windows or Linux version, but you'll have the source, so I don't think it would be that hard to get an agent to have a go."],
  ["Does it use my subscription or an API key?",
    "Your subscription. Threadbear runs the official <code>claude</code> and <code>codex</code> command line tools, logged in as you, the same as running them in a terminal. It never reads or copies your login tokens."],
  // Built: runner/src/sync.ts mirrors exactly this (docs/protocol.md, "Sync"). NOT BUILT: it
  // being the user's own deployment (today it's Mike's).
  ["What goes up to Convex?",
    "Each thread's title and status, its newest 20 messages, anything waiting on you, and your projects and schedules. Full transcripts, tool output and images stay on your Mac. It's your deployment in your own Convex account, so none of it comes to me."],
  ["Do I need the iPhone app?",
    "No, the Mac app does everything on its own. The iPhone app and the browser links are for when you're away from your desk."],
  ["What can a patch do?",
    "Add buttons above the message box that run a command or send a prompt, add panels beside the thread (a web page, or a list Threadbear draws itself), and run a command after each turn, like a typecheck, telling the agent when it fails. A patch is a plain file in your repo, so it gets reviewed and committed like anything else."],
  ["Why would I want my own copy of the code?",
    "So you can change anything you like. Threadbear is the app I wanted, and yours probably wants to be a bit different. Your agents can work on it like any other project, and you never have to wait for me to add something."],
  ["Will you add a feature for me?",
    "Probably not, to be totally honest. It's my own tool and I mostly build what I use. But you'll have the source, and adding things is kind of the point."],
  ["Why is it called Threadbear?",
    "A threadbare teddy is the one you've had for years, worn and patched and loved for it, and that's what I wanted this to be. There are a few bear words in the app too: snoozing a thread is Hibernate, the archive is the Den, and while an agent works it says Bear with me."],
  ["When can I get it?",
    "Not quite yet. The code is private for now and goes public a bit later, and the iPhone app is on its way to the App Store. Once they're out, the buttons on this page turn into links."],
];

function faq() {
  const items = FAQ.map(([q, a]) => `        <article class="faq-item"><h3>${q}</h3><p>${a}</p></article>`);
  return `<div class="faq-list">\n${items.join("\n")}\n      </div>`;
}

/** schema.org data for the home page, so search engines know what Threadbear is. */
function structuredData() {
  const app = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Threadbear",
    description: "A Mac app Mike Cann made for running Claude Code and Codex threads on your own subscriptions, with an iPhone app, a link per thread and patches your agents can write.",
    operatingSystem: "macOS 26 or later, Apple silicon",
    applicationCategory: "DeveloperApplication",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    url: `${SITE_URL}/`,
    image: `${SITE_URL}/img/icon-512.png`,
    screenshot: Object.keys(MAC).map((name) => `${SITE_URL}/screens/${name}.webp`),
    author: { "@type": "Person", name: "Mike Cann", url: "https://mikecann.app" },
    ...(GITHUB_PUBLIC ? { codeRepository: GITHUB_URL } : {}),
  };
  const faqPage = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: FAQ.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a.replace(/<[^>]+>/g, "") } })),
  };
  const json = JSON.stringify([app, faqPage]).replace(/</g, "\\u003c");
  return `<script type="application/ld+json">${json}</script>`;
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

/** A Phosphor icon (src/icons, MIT), inlined so it takes the text colour and needs no request. */
function icon(name) {
  const file = join(src, "icons", `${name}.svg`);
  if (!existsSync(file)) throw new Error(`No icon called ${name} in src/icons (scripts/icons.mjs adds them)`);
  return readFileSync(file, "utf8").trim()
    .replace("<svg ", '<svg class="icon" aria-hidden="true" focusable="false" ')
    .replace(/ xmlns="[^"]*"/, "");
}

/** Fills {{name}} from `values`, and {{mac ...}}, {{phone ...}} and {{icon ...}}. */
function fill(template, values) {
  return template.replace(/\{\{(\w+)((?: [\w-]+)*)\}\}/g, (match, key, args) => {
    if (key === "mac") return mac(...args.trim().split(" "));
    if (key === "phone") return phone(...args.trim().split(" "));
    if (key === "icon") return icon(args.trim());
    return key in values ? values[key] : match;
  });
}

/** Copies a file into dist with a hash of its contents in the name, so it can be cached for good. */
function fingerprint(name) {
  const body = readFileSync(join(src, name));
  const hash = createHash("sha256").update(body).digest("hex").slice(0, 8);
  const hashed = name.replace(/\.(\w+)$/, `.${hash}.$1`);
  writeFileSync(join(dist, hashed), body);
  return `/${hashed}`;
}

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
cpSync(join(root, "public"), dist, { recursive: true, filter: (from) => !from.endsWith(".DS_Store") });

const styles = fingerprint("styles.css");
const siteScript = fingerprint("site.js");
const layout = readFileSync(join(src, "layout.html"), "utf8");
const shared = {
  site: SITE_URL, styles, commits: commits.toLocaleString("en-AU"), firstDay,
  appStoreBadge: appStoreBadge(), fork: fork(), faq: faq(), githubCorner: githubCorner(),
  // Moves the top bar in to clear the corner, when there is one.
  bodyClass: GITHUB_PUBLIC ? " has-corner" : "",
};

/**
 * Wraps a page's content in the layout, checks it and writes it to dist/<name>.html. `page` is
 * its { title, description, path }; `name` is its address without the slash ("docs/threads").
 */
const built = new Map();
function writePage(name, page, content, label = `${name}.html`) {
  const url = page.path && SITE_URL + page.path;
  const inDocs = name === "docs" || name.startsWith("docs/");
  const out = fill(layout, {
    ...shared,
    title: escape(page.title), description: escape(page.description), page: name.replace(/\//g, "-"),
    // The 404 page has no address of its own, so it isn't canonical anywhere and isn't indexed.
    canonical: url ? `<link rel="canonical" href="${url}">\n  <meta property="og:url" content="${url}">` : '<meta name="robots" content="noindex">',
    homeCurrent: name === "index" ? ' aria-current="page"' : "",
    privacyCurrent: name === "privacy" ? ' aria-current="page"' : "",
    supportCurrent: name === "support" ? ' aria-current="page"' : "",
    // Every docs page is under Docs in the nav, so it's marked there too (the index only in
    // the docs list, where it's the page itself).
    docsCurrent: inDocs ? ' aria-current="page"' : "",
    structuredData: name === "index" ? structuredData() : "",
    script: `<script src="${siteScript}" defer></script>`,
    content,
  });
  if (/\{\{[\w -]+\}\}/.test(out)) throw new Error(`${label} has a {{placeholder}} left over: ${out.match(/\{\{[\w -]+\}\}/)[0]}`);
  // Em and en dashes read as written by a machine, so they never go out.
  if (/[—–]/.test(out)) throw new Error(`${label} has an em or en dash in it: ${out.match(/.{0,40}[—–].{0,40}/)[0]}`);
  // The Worker's CSP has no 'unsafe-inline' for styles, so a style="" would be ignored.
  if (/\sstyle="/.test(out)) throw new Error(`${label} has a style="" attribute, which the CSP blocks`);
  // The comments are notes for whoever edits the page (including which claims aren't built
  // yet), so they stay in src and never ship.
  const shipped = out.replace(/\n?[ \t]*<!--[\s\S]*?-->/g, "");
  mkdirSync(dirname(join(dist, `${name}.html`)), { recursive: true });
  writeFileSync(join(dist, `${name}.html`), shipped);
  built.set(name, { page, html: shipped });
}

const pages = readdirSync(src).filter((f) => f.endsWith(".html") && f !== "layout.html");
for (const file of pages) {
  const html = readFileSync(join(src, file), "utf8");
  const match = html.match(/^<!--page (\{.*?\}) -->\n/);
  if (!match) throw new Error(`${file} needs a <!--page {...} --> line first`);
  writePage(file.replace(/\.html$/, ""), JSON.parse(match[1]), fill(html.slice(match[0].length), shared).trimEnd(), file);
}

/**
 * The docs: /docs lists the guide's sections, and each is a page of its own at /docs/<slug>,
 * with the list down the side and the next section at the foot. app-doc-slugs.json is the
 * slugs the Mac app links to, which the guide must keep.
 */
const appDocSlugs = JSON.parse(readFileSync(join(root, "app-doc-slugs.json"), "utf8"));
const guide = readGuide(join(root, ".."), appDocSlugs);
const docSlugs = new Set(guide.sections.map((s) => s.slug));
function docsNav(current) {
  const items = guide.sections.map(({ slug, title }) =>
    `          <li><a href="/docs/${slug}"${slug === current ? ' aria-current="page"' : ""}>${escape(title)}</a></li>`);
  return `      <nav class="docs-nav" aria-label="Docs">
        <a class="docs-home" href="/docs"${current ? "" : ' aria-current="page"'}>${escape(guide.title)}</a>
        <ol>
${items.join("\n")}
        </ol>
      </nav>`;
}
writePage("docs", {
  title: `${guide.title} · Threadbear`,
  description: "How to use Threadbear: threads, panels, Highlights, patches, your phone and the rest, one page a part.",
  path: "/docs",
}, `    <div class="docs">
${docsNav(null)}
      <article class="legal doc">
        <h1>${escape(guide.title)}</h1>
        <div class="doc-intro">
${markdown(guide.intro, docSlugs)}
        </div>
        <ol class="doc-index">
${guide.sections.map(({ slug, title }) => `          <li><a href="/docs/${slug}">${escape(title)}</a></li>`).join("\n")}
        </ol>
      </article>
    </div>`);
guide.sections.forEach(({ slug, title, body }, index) => {
  const next = guide.sections[index + 1];
  writePage(`docs/${slug}`, { title: `${title} · Threadbear docs`, description: summary(body) || `${title}, from the Threadbear guide.`, path: `/docs/${slug}` }, `    <div class="docs">
${docsNav(slug)}
      <article class="legal doc">
        <h1>${escape(title)}</h1>
${markdown(body, docSlugs)}
        ${next ? `<p class="doc-next"><a href="/docs/${next.slug}">Next: ${escape(next.title)}</a></p>` : `<p class="doc-next"><a href="/docs">All the docs</a></p>`}
      </article>
    </div>`, `docs/${slug} (docs/guide.md)`);
});

// Every link and image that stays on the site has to land somewhere: a page, a file, and the
// #anchor on it if there is one.
for (const [name, { html }] of built) {
  for (const [, attr, target] of html.matchAll(/\s(href|src)="(\/[^"]*)"/g)) {
    const [path, anchor] = target.split("#");
    const clean = path.split("?")[0];
    const pageName = clean === "/" ? "index" : clean.slice(1);
    const page = built.get(pageName);
    if (!page && !existsSync(join(dist, clean))) throw new Error(`${name}.html: ${attr}="${target}" goes nowhere`);
    if (anchor && !(page ?? built.get(name)).html.includes(` id="${anchor}"`)) throw new Error(`${name}.html: ${target} has no #${anchor}`);
  }
}

const urls = [...built.values()].map(({ page }) => page.path).filter(Boolean).sort()
  .map((p) => `  <url><loc>${SITE_URL}${p}</loc></url>`).join("\n");
writeFileSync(join(dist, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
console.log(`Built ${pages.length} pages and ${guide.sections.length + 1} docs pages into site/dist (${commits} commits since ${firstDay}).`);
