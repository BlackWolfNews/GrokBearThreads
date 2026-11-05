import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// A click on Send, Archive or Snooze shows something at once, however
/// long the runner takes to answer (a loaded Mac stalls it for seconds).
@MainActor
final class PendingSendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// Making a new thread saves its login as the last one used, which
    /// would outlive the run and pick the login in other tests.
    override func tearDown() {
        for key in [AppModel.lastAccountKey, "lastAccountId.byProvider", "lastAccountId.codex.byProvider"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func connected() async throws -> (AppModel, HoldingTransport) {
        let app = AppModel()
        let transport = HoldingTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        app.threads["th1"] = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"th1","title":"Fix it","lastSeq":12}"#.utf8))
        return (app, transport)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The message shows on its way before the runner has answered, and a
    /// failed send takes it away and puts the draft back.
    func testASentMessageShowsAtOnceAndAFailureTakesItBack() async throws {
        let (app, transport) = try await connected()
        let session = app.session(for: "th1")
        app.drafts["th1"] = Draft(text: "Ship it")
        app.send(threadId: "th1")
        XCTAssertNil(app.drafts["th1"], "the box empties")
        XCTAssertEqual(session.pending.map(\.text), ["Ship it"], "and the message shows straight away")
        XCTAssertEqual(session.pending.first?.afterSeq, 12, "only a user.message after the thread's last seq can be it")
        XCTAssertEqual(session.pending.first?.queued, false)
        try await until { transport.waiting("threads.send") }
        transport.fail("threads.send", message: "Busy")
        try await until { app.drafts["th1"] != nil }
        XCTAssertEqual(app.drafts["th1"]?.text, "Ship it")
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(app.errorMessage, "Busy")
    }

    /// The pictures' chips go as [Picture N] markers where they sat, the
    /// pictures in the chips' order (docs/protocol.md, "Pictures in a
    /// message"); a failed send puts the chips back.
    func testChipsGoAsPictureMarkersWhereTheySat() async throws {
        let (app, transport) = try await connected()
        let session = app.session(for: "th1")
        let mark = InlinePictures.markString
        let red = ImageRef(path: "/inbox/red.png", mediaType: "image/png")
        let blue = ImageRef(path: "/inbox/blue.png", mediaType: "image/png")
        let draft = Draft(text: "this \(mark) should look like \(mark) ", images: [red, blue])
        app.drafts["th1"] = draft
        app.send(threadId: "th1")
        XCTAssertEqual(session.pending.first?.text, "this [Picture 1] should look like [Picture 2]")
        XCTAssertEqual(session.pending.first?.images, [red, blue])
        try await until { transport.waiting("threads.send") }
        transport.fail("threads.send", message: "Busy")
        try await until { app.drafts["th1"] != nil }
        XCTAssertEqual(app.drafts["th1"], draft)
        // Pictures and no words go as pictures alone, as they always did.
        app.drafts["th1"] = Draft(text: "\(mark) \(mark)", images: [red, blue])
        app.send(threadId: "th1")
        XCTAssertEqual(session.pending.last?.text, "")
        XCTAssertEqual(session.pending.last?.images, [red, blue])
    }

    /// A send the old runner turns away while restarting (it let the idle
    /// thread go, or is letting it go, before the new one was up) goes
    /// again to the new runner once it's connected. It shows as on its way
    /// the whole time, through the dropped connection, with no error and
    /// the box left empty (Mike saw "Thread not found", 5 Nov).
    func testASendTurnedAwayByARestartGoesAgainToTheNewRunner() async throws {
        let refusals = [
            (RPCError.threadNotFound, "Thread not found: th1"),
            (RPCError.busy, "The runner is handing over to a new one; send again in a moment."),
        ]
        for (code, message) in refusals {
            let (app, old) = try await connected()
            let session = app.session(for: "th1")
            _ = app.restart(notice: "The runner is restarting onto a new release.")
            app.drafts["th1"] = Draft(text: "what is Magisk?")
            app.send(threadId: "th1")
            try await until { old.waiting("threads.send") }
            old.fail("threads.send", code: code, message: message)
            try await Task.sleep(for: .milliseconds(300))
            // The old runner drops the socket, as it does.
            session.connectionLost()
            XCTAssertEqual(session.pending.map(\.text), ["what is Magisk?"], "still on its way while the runner restarts: \(message)")
            XCTAssertNil(app.drafts["th1"])
            let new = HoldingTransport()
            let client = RPCClient(transport: new)
            try await client.start()
            app.useClientForTesting(client)
            try await until { new.waiting("threads.send") }
            XCTAssertEqual(new.count("threads.send"), 1)
            new.answer("threads.send", ["turnId": "turn_1"])
            try await until { session.pending.first?.queued == true }
            XCTAssertEqual(session.pending.first?.queued, true)
            XCTAssertNil(app.drafts["th1"])
            XCTAssertNil(app.errorMessage)
            // Once it's gone, a later drop clears it as usual.
            session.connectionLost()
            XCTAssertTrue(session.pending.isEmpty)
        }
    }

    /// Any other busy refusal, or "Thread not found" with no restart, still
    /// puts the draft back with the error.
    func testOtherRefusalsDuringARestartStillFail() async throws {
        let (app, transport) = try await connected()
        _ = app.restart(notice: "The runner is restarting onto a new release.")
        app.drafts["th1"] = Draft(text: "Ship it")
        app.send(threadId: "th1")
        try await until { transport.waiting("threads.send") }
        transport.fail("threads.send", message: "Busy")
        try await until { app.drafts["th1"] != nil }
        XCTAssertEqual(app.errorMessage, "Busy")
    }

    func testThreadNotFoundWithNoRestartStillFails() async throws {
        let (app, transport) = try await connected()
        app.drafts["th1"] = Draft(text: "Ship it")
        app.send(threadId: "th1")
        try await until { transport.waiting("threads.send") }
        transport.fail("threads.send", code: RPCError.threadNotFound, message: "Thread not found: th1")
        try await until { app.drafts["th1"] != nil }
        XCTAssertEqual(app.drafts["th1"]?.text, "Ship it")
        XCTAssertEqual(app.errorMessage, "Thread not found: th1")
    }

    /// Taken but not shown: queued behind the running turn. A dropped
    /// connection clears it (the runner brings it back with its turn).
    func testATakenMessageWithNoUserMessageShowsAsQueued() async throws {
        let (app, transport) = try await connected()
        let session = app.session(for: "th1")
        app.drafts["th1"] = Draft(text: "And the docs")
        app.send(threadId: "th1")
        try await until { transport.waiting("threads.send") }
        transport.answer("threads.send", ["turnId": "turn_1"])
        try await until { session.pending.first?.queued == true }
        XCTAssertEqual(session.pending.first?.queued, true)
        XCTAssertNil(app.drafts["th1"], "a message the runner took stays sent")
        session.connectionLost()
        XCTAssertTrue(session.pending.isEmpty)
    }

    /// A new thread's draft stays in the box, locked, until the runner has
    /// made the thread; a second Return meanwhile sends nothing.
    func testANewThreadKeepsItsDraftUntilItExists() async throws {
        let (app, transport) = try await connected()
        app.drafts["new"] = Draft(text: "Start something")
        app.send(threadId: nil)
        XCTAssertTrue(app.creatingThread)
        XCTAssertEqual(app.drafts["new"]?.text, "Start something", "the words stay while it's made")
        try await until { transport.waiting("threads.create") }
        app.send(threadId: nil)
        XCTAssertEqual(transport.count("threads.create"), 1, "Return again doesn't make a second thread")
        transport.answer("threads.create", ["thread": ["id": "th_new", "title": "Start something"]])
        try await until { app.selection == "th_new" }
        XCTAssertFalse(app.creatingThread)
        XCTAssertNil(app.drafts["new"])
    }

    func testANewThreadThatFailsLeavesTheDraftToSendAgain() async throws {
        let (app, transport) = try await connected()
        app.drafts["new"] = Draft(text: "Start something")
        app.send(threadId: nil)
        try await until { transport.waiting("threads.create") }
        transport.fail("threads.create", message: "Busy")
        try await until { !app.creatingThread }
        XCTAssertEqual(app.drafts["new"]?.text, "Start something")
        XCTAssertEqual(app.errorMessage, "Busy")
    }

    /// Archive shows at once; a refusal puts the thread back.
    func testArchiveShowsAtOnceAndARefusalPutsItBack() async throws {
        let (app, transport) = try await connected()
        app.update("th1", ThreadUpdate(archived: true))
        XCTAssertEqual(app.threads["th1"]?.isArchived, true)
        try await until { transport.waiting("threads.update") }
        transport.fail("threads.update", message: "Busy")
        try await until { app.threads["th1"]?.isArchived == false }
        XCTAssertEqual(app.threads["th1"]?.isArchived, false)
    }

    /// The guesses: what the runner will do for the simple fields, and
    /// nothing for a login or folder move, which can change more.
    func testWhatAnUpdateGuesses() throws {
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"th1","title":"Fix it","model":"opus","permissionMode":"full"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ThreadUpdate(archived: true).applied(to: thread, now: now).archivedAt, now)
        // The done card's Archive menu sends its pick with the archive, and only with one.
        XCTAssertEqual(ThreadUpdate(archived: true, verdict: .didntWork).params["verdict"], .string("didntWork"))
        XCTAssertNil(ThreadUpdate(archived: false, verdict: .worked).params["verdict"])
        XCTAssertNil(ThreadUpdate(archived: true).params["verdict"])
        let until = Date(timeIntervalSince1970: 5000)
        XCTAssertEqual(ThreadUpdate(snoozedUntil: .some(until)).applied(to: thread).snoozedUntil, until)
        XCTAssertTrue(ThreadUpdate(snoozeUntilRestart: true).applied(to: thread).snoozedUntilRestart)
        XCTAssertNil(ThreadUpdate(snoozedUntil: .some(nil)).applied(to: thread).snoozedUntil)
        XCTAssertEqual(ThreadUpdate(permissionMode: .ask).applied(to: thread).permissionMode, .ask)
        XCTAssertEqual(ThreadUpdate(model: .some("haiku")).applied(to: thread).model, "haiku")
        XCTAssertNil(ThreadUpdate(model: .some(nil)).applied(to: thread).model, "back to the default")
        XCTAssertEqual(ThreadUpdate(accountId: "codex-main", model: .some("gpt")).applied(to: thread), thread)
        XCTAssertEqual(ThreadUpdate(cwd: "/tmp").applied(to: thread), thread)
    }
}

/// Holds every request until the test answers or fails it, like a runner
/// whose event loop is stalled.
private final class HoldingTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var held: [(id: Int, method: String)] = []
    private var counts: [String: Int] = [:]

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        lock.lock()
        held.append((id, method))
        counts[method, default: 0] += 1
        lock.unlock()
    }

    func waiting(_ method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains { $0.method == method }
    }

    func count(_ method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[method] ?? 0
    }

    func answer(_ method: String, _ result: [String: Any]) {
        guard let id = take(method) else { return }
        push(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func fail(_ method: String, code: Int = -32020, message: String) {
        guard let id = take(method) else { return }
        push(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func take(_ method: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = held.firstIndex(where: { $0.method == method }) else { return nil }
        return held.remove(at: index).id
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {}

    private func push(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }
}
