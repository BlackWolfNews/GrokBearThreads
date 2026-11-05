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
// 9: schedules can live here rather than in each runner's schedules.json
//    (step 6; docs/protocol.md, Schedules, "Runners"): sync:schedules,
//    sync:saveSchedule, sync:deleteSchedule, sync:adoptSchedules,
//    sync:claimSchedule, sync:releaseSchedule, sync:scheduleRan and
//    sync:requestScheduleRun. A runner moves its schedules here only from 9.
// 10: phone:quickAsk queues a "quickAsk" command: a quick ask the phone
//    answered itself, which the runner keeps as a thread with no turn run.
// 11: a runner's heartbeat can carry `icon`, an SF Symbol for its Mac
//    (sync.icon, or worked out from the model), and sync:runnersList
//    returns it. A runner sends it only to a backend of 11 or later.
// 12: Bruce's threads in the Mac app (step 6, part 2): the threadIndex
//    table (sync:setThreadIndex, sync:otherRunnersThreads), and a runner's
//    heartbeat can carry rpcUrl, how a Mac app reaches it. A runner writes
//    the index and sends rpcUrl only to a backend of 12 or later.
// 13: thread rows can carry `woke` ({ at, since? }): back from hibernating
//    by itself and not opened yet, for the phone's "Woke up". A runner
//    sends it only to a backend of 13 or later.
// 14: the phone sees end-of-turn cards: thread rows carry the open card's
//    `asks` and `asksSeq` and a finished turn's `next`, a message row can be
//    `summary` (end_turn's bullets, the turn's reply), and phone:send takes
//    `answers`. A runner sends them only to a backend of 14 or later.
// 15: thread rows can carry `needs`, `pendingReviews` and `waitingForRoom`,
//    so the phone sorts threads into the Mac's sections (Waiting: idle
//    threads a schedule will message). A runner sends them only to a
//    backend of 15 or later.
// 16: phone:search({ token, text }) finds archived threads by the words in
//    their title or last reply, past the newest 100 phone:threads gives the
//    den. Nothing changes for runners.
// 17: phone:counts says how many threads are hibernating and archived, so
//    the phone can fold those sections without loading them.
// 18: photos from the phone. phone:imageUploadUrl gives somewhere to put one,
//    phone:send and phone:create take `images` (storage ids), and the command's
//    args carry each with its URL for the runner, which fetches it;
//    sync:finishCommand deletes them. Nothing changes for an older runner
//    until a phone sends a photo, which it only does from 18.
// 19: the Pocket. phone:pocket and phone:removePocketCard for the phone,
//    sync:savePocketCard, sync:removePocketCard and sync:pocketCards for the
//    runner's `pocket` tool. Nothing else changes for older clients.
// 20: the phone's new thread pickers. Account rows carry `models` ({ id,
//    title, effortLevels?, defaultEffort? }) and `defaultEffort`, and
//    phone:create takes `effort`. A runner sends models only to a backend
//    of 20 or later; an older runner ignores an effort.
// 21: a Pocket card can have an `icon`; filing one again without keeps it.
// 22: thread rows can carry `startedBy` ({ kind, label, icon?, why? }): who
//    started it when Mike didn't, for the phone's byline. A runner sends it
//    only to a backend of 22 or later; an older phone ignores it.
// 23: threadIndex rows can carry `startedBy` too, so the Mac's sidebar shows
//    the byline on another runner's threads. A runner sends it only to a
//    backend of 23 or later.
// 24: pictures for the phone, from every thread. sync:replyImages and
//    sync:addReplyImage take the pictures in agents' replies and pinned
//    pictures, and phone:messages' `images` carries them (a pinned one with
//    `pinned`). Nothing changes for an older runner or phone, which just
//    doesn't have them.
// 25: phone:discardImage, for a photo the phone uploaded and never sent. A
//    phone only ever calls it on a best-effort basis, so on an older backend
//    the photo just stays in file storage, and an older phone never calls it.
// 26: a message row can carry `turn`, which turn it's from, and phone:messages
//    returns it, so the phone can tell a turn the CLI started itself from the
//    one before. A runner sends it only to a backend of 26 or later, and a
//    phone without it reads the rows as it always did.
// 27: stars. Thread and threadIndex rows can carry `starredAt`, a starred
//    thread that's hibernating stays in view "inbox", and phone:update takes
//    `star`. A runner sends them only to a backend of 27 or later; an older
//    phone doesn't show the section, and misses a thread that's both
//    starred and hibernating until it's updated.
// 28: thread rows can carry `links` ({ title, url, icon? }[]): the thread's
//    patch link buttons (url actions), which the phone shows and opens
//    itself. A runner sends them only to a backend of 28 or later; an older
//    phone ignores them.
// 29: watching only what changed. threadIndex rows carry `updatedMs` and a
//    gone thread's row stays a day as a `deleted` tombstone;
//    sync:otherRunnersList and sync:threadIndexSince let a runner watch the
//    other runners and only their rows changed since its last answer.
//    sync:otherRunnersThreads skips tombstones, so an older runner sees no
//    change.
// 30: fewer reads. sync:upsertProjects takes only the projects that changed
//    (and the ones gone), so a turn no longer rewrites every project; the
//    runner still sends the whole list with setProjects once after it
//    starts. phone:counts reads a viewCounts row per runner, kept by the
//    thread writes, rather than every hibernating and den thread. Nothing
//    changes for a phone or an older runner.
// 31: thread rows can carry `asked`, what Mike last said to the thread in
//    one line, which the phone shows under the title as "You: ...". A
//    runner sends it only to a backend of 31 or later; an older phone
//    ignores it and shows the thread's place as before.
// 32: threadIndex rows can carry `asked` too, so a Mac's sidebar shows
//    "You: ..." under another runner's threads. A runner sends it only to a
//    backend of 32 or later; an older app ignores it.
// 33: the first message row of a turn the agent started by itself, as a
//    sub-agent or background job finished, can carry `wokeBy` (what
//    finished), and phone:messages passes it on, so the phone marks the
//    wait as "6 min later · Mine the repo finished". A runner sends it
//    only to a backend of 33 or later; an older phone ignores it.
// 34: thread rows can carry `waitingForNetwork` ({ since }): its last turn
//    couldn't reach the API and it carries on by itself once the runner
//    can, so the phone's row says "Waiting for connection", not Failed. A
//    runner sends it only to a backend of 34 or later; an older phone
//    ignores it and shows Failed.
// 35: secrets (docs/protocol.md, "Secrets"). A thread row's
//    pendingApproval can be `kind: "secret"` with the card's label, reason
//    and the runner's public key; phone:secret queues the phone's sealed
//    answer (or a decline) as a respond command, and finishCommand drops
//    the sealed answer from the row. A runner sends a secret card only to a
//    backend of 35 or later; an older phone shows the thread waiting.
// 36: an owned schedule can carry `poolId`, the pool that picks the login
//    each of its threads starts on, instead of `accountId`. A runner sends
//    it only to a backend of 36 or later; an older runner ignores it and
//    starts the thread on its folder's pool.
// 37: less database I/O (docs/convex-backend.md, "Usage and the free plan").
//    sync:upsertAccounts writes only the logins that changed; sync:heartbeat
//    can say firstSeen, so a runner that remembers what it has written
//    between starts writes it again for a deployment that's never met it;
//    phone:threadRow is a thread's row without its messages, and phone:images
//    a thread's pictures, with phone:messages' noImages. A runner uses
//    upsertAccounts only with a backend of 37 or later and ignores firstSeen
//    from none; an older phone goes on using phone:thread.
// 38: pools shared between runners (docs/protocol.md, "Pools"): the
//    `pools` table, sync:pools, sync:savePools and sync:adoptPools. A runner
//    follows it only with a backend of 38 or later; before, each keeps its
//    own runner.json pools.
export const API_VERSION = 38;
