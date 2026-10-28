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
- `Threadbear/`: the SwiftUI app. iOS 18, so the XS Max runs it too.
- `scripts/sim-shots.sh [dir] [--dark]`: screenshots on sample data in the
  simulator (`-ThreadbearFake`, `-ThreadbearOpen <threadId>`).
- `scripts/install-phone.sh`: build, install over wifi, launch.
- `scripts/make-icon.swift`: the icon, from the same mascot as the Mac's.

## Pairing

The phone carries a phone token (`convex/tokens.ts`), never the runner key.
Make one with `npx convex run tokens:issue '{"name":"iphone","days":90}'`
(`--prod` for prod), then get it onto the phone as a link:

    threadbear://pair?url=<https://….convex.cloud>&token=<tb_…>

shown as a QR code that Threadbear's Scan the code (or the Camera) reads. `swift ios/scripts/pair-qr.swift` does all of this, never printing the token or leaving the image on disk, or pasted from the phone's own
clipboard ("Paste a pairing link"). Not through the Mac clipboard: Quick
Ask's key leaked that way. The app checks the token with `phone:me` before
keeping it, in the Keychain keyed by deployment. Debug builds also take
`http://127.0.0.1:3210`, the local `npx convex dev` backend, for the
simulator.

## Push

`phone:registerDevice` with the APNs token. Builds from `install-phone.sh`
are development-signed, so they're `sandbox`. Tapping a notification opens
its `threadId`.
