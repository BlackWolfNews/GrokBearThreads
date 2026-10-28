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
// 5: project icons. phone:projects rows carry `icon` ({ symbol?, url?, by }),
//    the url a picture in file storage the runner uploads (sync:iconUploadUrl,
//    sync:setProjectIcon); a runner before 5 sends projects without icons.
// 6: sync:issueToken, sync:listTokens and sync:revokeToken, so the Mac app
//    pairs phones and signs browsers in through the runner (docs/protocol.md,
//    "Devices") with no Convex CLI; tokens carry a kind.
// 7: sharing (docs/website.md, "Sharing"). Thread rows carry `share`
//    ({ access, slug, people? }), and share:view, share:sendCode and
//    share:verifyCode serve /s/<slug> without a phone token. A runner sends
//    `share` only to a backend of 7 or later.
// 8: sharing is a public link or nothing (specific people and their email
//    codes are gone). `share.access` can be "off", so Mike's page keeps
//    its controls; phone:share queues a "share" command; and a shared
//    thread's pictures go to file storage (sync:addShareImage), shown by
//    share:view. A runner sends `share` only to a backend of 8 or later.
export const API_VERSION = 8;
