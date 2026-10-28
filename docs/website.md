# The website

Threadbear in a browser, so a thread has a link you can paste anywhere:
`https://opulent-moose-249.ap-southeast-2.convex.site/t/<threadId>`.
Built 28 Oct 2026 (thread 66935d23).

## What it is

- `web/`: a small Vite + React app. The inbox, hibernating and den lists on
  the left, a thread on the right (one column on a phone). A thread shows
  the mirrored messages, its pending approval or question with buttons, a
  composer, Load earlier messages, and Hibernate / Wake / To the den / Copy
  link. Opening a thread marks it seen.
- It's a client of the phone's API (`convex/phone.ts`, docs/convex-backend.md
  section 6) and nothing else, so it sees exactly what the phone sees: the
  newest 20 text messages per thread, no tool output or images. Everything
  it does is a `commands` row the runner applies.
- Hosted by `@convex-dev/static-hosting` on the same Convex deployment
  (`convex/convex.config.ts` mounts it at `/`; our own HTTP routes would go
  under `/api`). Unknown paths fall back to `index.html`, so `/t/<id>` works
  cold.
- The Mac app's thread `...` menu has **Copy web link**. It takes the site
  from `runner.status`'s `sync.url` (`.convex.cloud` → `.convex.site`), so
  it only shows while sync is on.

## Sharing

A thread can be shared by link (docs/protocol.md, "Sharing"): from the
share button beside the Mac app's ... menu, or from the website, where
Mike's own thread page and the shared page (when he's signed in) have a
Share button: Share with a link, Copy, Stop sharing, and on his thread
page New link. Those queue a `share` command (`phone:share`) the runner
applies, as the Mac's button does. Built 28-29 Oct 2026 (thread ec75fe8b,
backend APIs 7 and 8).

The link is `<site>/s/<slug>`, a page with no sign-in (`web/src/share.tsx`),
read-only and live, served by `share:view` (`convex/share.ts`), the only
function that takes no phone token. It gives the title, the messages, the
tool lines and the thread's pictures, and nothing else; or `gone` for a
link that isn't shared. With Mike's token it also answers while the
thread isn't shared, with `manage`, so his page keeps its controls.

Pictures are in file storage (`shareImages`), uploaded by the runner only
while the thread is shared and dropped when it stops. A picture written in
a message's Markdown (`src`) takes the place of that Markdown image; the
rest go after the row they came with. Mike's own thread page shows them
too (`phone:messages` returns them). A Markdown picture that wasn't
uploaded shows as its alt text, not a broken image.

Sharing with specific people (an emailed code, through Resend) was built
on 28 Oct and taken out on 29 Oct: Mike wanted a public link and nothing
else for now, and it needed a Resend key Threadbear doesn't have.

## Signing in

The browser holds a phone token (`convex/tokens.ts`) in localStorage. The
Mac app issues one through the runner (docs/protocol.md "Devices"):
Settings › Phone & browser › "Open signed in" opens the site in the default
browser with the token in the link's `#fragment`, and the same tab lists
the signed-in browsers with Revoke. Since 28 Oct that's the usual way.

From a terminal, by someone logged in to the Convex team:

    npm run web:sign-in                  # Chrome on this Mac, prod, 90 days
    npm run web:sign-in -- --qr          # a QR code for another device
    npm run web:sign-in -- --dev         # the dev deployment's site
    npm run web:sign-in -- --local       # Vite on localhost:5181, dev data

`web/scripts/sign-in.swift` puts the token in the link's `#fragment`, which
browsers never send to a server; the page keeps it and wipes it from the
address bar. The token is never printed. Revoke a browser from Settings ›
Phone & browser, or with `npx convex run tokens:revoke '{"name":"web-mac"}'
--prod`; it then shows the sign-in page. The page is `noindex` and sends no referrer.

## Working on it

    VITE_CONVEX_URL=https://earnest-puffin-640.ap-southeast-2.convex.cloud npm run web:dev
    npm run web:sign-in -- --local

The dev deployment has no threads unless a dev runner mirrors to it, so for
a real look use prod data with a throwaway token (`--name web-test --days 1`,
revoke after).

**Deploying:** `npm run web:deploy` runs `convex deploy` (prod) and then
uploads `web/dist`. It asks before pushing to prod; from an agent, answer
through a pseudo-terminal (`(sleep 40; printf 'y\r') | script -q /dev/null
npm run web:deploy`). For a site-only change,
`npx static-hosting upload --build --build-command 'npm run web:build' --dist web/dist --prod`.
A plain `npm run web:build` refuses to run without `VITE_CONVEX_URL`, which
the static-hosting CLI sets: a build without it can't reach Convex.

## Not done

- A custom domain (e.g. threadbear.mikecann.app) instead of the
  `.convex.site` host.
- Signing in from a browser without the Mac to hand (e.g. approve a new
  browser from the iPhone app). A QR code for another device's browser is
  still `npm run web:sign-in -- --qr`.
- Starting a new thread from the web (`phone:create` is there to use).
- Sharing from the iPhone app or an agent's tools.
