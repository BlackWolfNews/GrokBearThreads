// The backend's API version: what the runner and the phone app can expect
// from these functions. Bump it when a change adds something a client relies
// on, and change clients to cope with the old number first, since a phone
// from the App Store and an older runner can both meet a newer backend (and
// the other way round) while an update rolls out.
// docs/setup-and-updates.md section 2.3.
//
// The runner checks it against its own BACKEND_API_VERSION (runner/src/sync.ts;
// a unit test keeps the two equal) and says so when its backend is older.
//
// 1: the phone API of 27 Oct (docs/convex-backend.md section 6), plus this
//    number on sync:heartbeat and phone:me.
// 2: every message is kept, with one line per tool call (role "tool");
//    phone:messages pages through them. phone:thread is unchanged for API 1
//    phones and never returns tool rows.
// 3: presence (sync:setPresence from the runner) and each phone's
//    notification setting (phone:setNotifications): "away" phones only get
//    a push while Mike isn't at the Mac.
// 4: phone:registerDevice takes the phone's pushKey; a backend without its
//    own Apple key sends pushes through the push relay, encrypted with it.
export const API_VERSION = 4;
