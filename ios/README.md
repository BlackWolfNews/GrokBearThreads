# Threadbear for iPhone

The phone side of Threadbear: the inbox, a thread's last messages, replies
(typed or dictated), approvals and questions, Hibernate and the Den, new
threads and push. It reads the Convex mirror the runner writes
(`docs/convex-backend.md`, `convex/phone.ts`) and never talks to the runner
directly, so it works with the Mac asleep: whatever you send waits in
`commands` until the runner is back.

- `ThreadbearKit/`: the rows, the inbox order (same rules as the Mac
  sidebar), the Convex transport, a `FakeBackend` with sample data. `swift
  test` runs on the Mac.
- The rows look like the Mac sidebar's (`Threadbear/Look.swift`): the
  project's tile with its picture (from `phone:projects`, backend API 5,
  fetched once and kept in `ProjectPictures`), its symbol or first
  letter, a second tile's edge behind it for a thread in two projects, the
  unread dot or done tick in the gutter, the status in the Mac's colours
  (accent while working, orange for Needs you, red for Failed) and the
  same section headings. The accent is the system blue the Mac's accent
  is.
- `Threadbear/`: the SwiftUI app. iOS 18, so the XS Max runs it too.
- `scripts/sim-shots.sh [dir] [--dark]`: screenshots on sample data in the
  simulator (`-ThreadbearFake`, `-ThreadbearOpen <threadId>`,
  `-ThreadbearCompose <text>`), on a 6.9" iPhone, so they're App Store sized.
- `appstore/` and `scripts/appstore-*`: the App Store listing and release,
  in `appstore/RELEASE.md`.
- `scripts/install-phone.sh`: build, install over wifi, launch.
- `scripts/make-icon.swift`: the icon, from the same mascot as the Mac's.

## The demo

"Look around with sample threads", at the bottom of the pair screen, runs
the app on `FakeBackend`'s made-up threads, on the phone only. It's how App
Review sees the app working without a token into anyone's deployment, so
the sample data must never name Mike's own projects or machines
(`sampleDataHasNothingPersonal`). The menu and Settings have "Leave the
demo", back to pairing. It isn't remembered across launches.

## Pairing

The phone carries a phone token (`convex/tokens.ts`), never the runner key.
The Mac app makes one: Settings › Phone & browser › "Show the code" shows
the pairing QR code (the runner issues the token, docs/protocol.md
"Devices"), and the same tab lists paired phones with Revoke. By hand,
`npx convex run tokens:issue '{"name":"iphone","days":90}'` (`--prod` for
prod) makes one, to get onto the phone as a link:

    threadbear://pair?url=<https://….convex.cloud>&token=<tb_…>

shown as a QR code that Threadbear's Scan the code (or the Camera) reads. `swift ios/scripts/pair-qr.swift` does all of this, never printing the token or leaving the image on disk, or pasted from the phone's own
clipboard ("Paste a pairing link"). Not through the Mac clipboard: Quick
Ask's key leaked that way. The app checks the token with `phone:me` before
keeping it, in the Keychain keyed by deployment. Debug builds also take
`http://127.0.0.1:3210`, the local `npx convex dev` backend, for the
simulator.

## Push

`phone:registerDevice` with the APNs token. Builds from `install-phone.sh`
are development-signed, so they're `sandbox`; App Store builds (Release,
`THREADBEAR_APS_ENVIRONMENT = production`) are `production`. In 1.0 the
pushes come straight from the paired deployment with Mike's key
(`convex/push.ts`); the relay in docs/setup-and-updates.md 2.4 is later. Tapping a notification opens
its `threadId`.
