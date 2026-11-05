# The push relay

The one shared piece of Threadbear. Built 28 Oct 2026 (thread 66935d23);
the decisions are in docs/setup-and-updates.md section 2.4.

## Why it exists

Apple only delivers a notification to the App Store app if it's signed with
the key of the developer account that published it: Mike's. That key also
signs for his other apps, so it can't go into other people's Threadbear
backends. The relay is a small Convex project of Mike's that holds the key
and forwards notifications for them. Everything else in Threadbear runs on
each person's own Mac and their own Convex deployment.

## What it sees, and what it keeps

- **Sees:** a device token, whether it's a development or App Store install,
  a thread id (a random UUID), and the notification **sealed** with a key
  only that phone and its own backend have. It never sees the title or text.
- **Keeps:** one row per Threadbear install (a random id, the hash of its
  key, when it was made and last seen, the version it says it is, and for
  backends from 5 Nov 2026 the address of the Convex deployment it
  registered for) and daily totals (notifications sent and failed, new
  installs). No device tokens, no thread ids, nothing per notification.
- **Opting out:** `npx convex env set PUSH_RELAY off` on your deployment. Then
  nothing goes to the relay, and the phone gets no notifications (they'd have
  to come from somewhere). Mike can forget an install:
  `npx convex run relay:forget '{"installId":"i_..."}' --prod` in `relay/`.

## How a notification travels

1. The phone makes 32 random bytes the first time (`PushKeyStore`, in the
   keychain under an App Group its notification extension shares) and sends them to its
   own backend with `phone:registerDevice` (API 4), never anywhere else.
2. When a thread needs Mike, `convex/push.ts` seals `{title, body}` with that
   phone's key (AES-256-GCM: nonce, ciphertext, tag, base64) and posts it to
   the relay's `/send` with the backend's install id and key (registered once
   through `/register` and kept in the `relayInstall` table; see
   "Registering" below).
3. The relay sends Apple a stand-in ("Threadbear: A thread needs you") with
   `mutable-content` and the sealed text in `e`.
4. The app's notification extension (`ios/NotificationService`) opens `e`
   with the key and shows the real title and text. If it can't, the stand-in
   shows.

A backend with its own Apple key (`APNS_*` env: Mike's) sends directly and
skips the relay. `PUSH_VIA=relay` sends through the relay anyway, for testing.

## Registering

`/register` is open to anyone, so it can't simply hand out installs from
one shared daily allowance: a script used to be able to use all 500 up and
stop every new backend from getting notifications (Daybreak scan, 5 Nov
2026). Callers can't be told apart by address either, since every backend
calls from Convex's servers. So a backend from 5 Nov sends its own
deployment address (`CONVEX_SITE_URL`) and a random nonce, which it also
keeps in its `relayChecks` table. The relay posts `{ nonce }` to that
deployment's `/relay/verify` (`convex/http.ts`), which says yes only to a
nonce it made in the last five minutes, once. Only someone running the
deployment passes, so each deployment gets one install (registering again
gives it a new key) and nobody can use up anyone else's. The relay only
calls back to `https://<name>[.<region>].convex.site`.

Older backends, and ones not on Convex's own hosts (self-hosted, a custom
domain), still register the old way, from a smaller shared allowance:
using it up blocks only those. Installs that already work are never
affected. The code is `relay/convex/verify.ts` and `relay.ts`.

## The project

- Code: `relay/` (its own package and `convex/`). Convex project
  `threadbear-relay` on team mikec: prod `impartial-hound-393` (Sydney,
  `https://impartial-hound-393.ap-southeast-2.convex.site`), dev
  `clean-terrier-424`. Env: the same `APNS_*` as Threadbear's prod.
- Limits: 120 sends an hour per install; 20 registrations a day per checked
  deployment; 100 new installs a day in total registered the old way.
- Stats for Mike: `npx convex run relay:stats --prod` in `relay/`.
- Deploy: `npm ci` then `npx convex deploy` in `relay/`, signed in to the
  Convex CLI as Mike (it isn't part of the runner's backend deploy, which
  is for each person's own deployment). Either side can go first: an old
  relay ignores the new fields, and old backends register the old way.
