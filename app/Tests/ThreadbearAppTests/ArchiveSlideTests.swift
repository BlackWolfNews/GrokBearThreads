import XCTest
import ThreadbearCore
@testable import Threadbear

/// A thread archived any way but a swipe (the archive button, ⌘E, the done
/// card, an agent, the phone) slides its row off first, as a swiped row does.
@MainActor
final class ArchiveSlideTests: XCTestCase {
    private func app(archiving: Bool) async throws -> AppModel {
        let app = AppModel()
        let client = RPCClient(transport: ArchivingTransport(archives: archiving))
        try await client.start()
        app.useClientForTesting(client)
        app.threads["a"] = ThreadSummary(id: "a", title: "Fix the build", status: .idle)
        return app
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testArchivingSlidesTheRowOffThenArchives() async throws {
        let app = try await app(archiving: true)
        app.archive("a")
        XCTAssertTrue(app.slidingOff.contains("a"))
        XCTAssertEqual(app.threads["a"]?.isArchived, false, "still in the inbox while it slides")
        try await waitUntil { app.threads["a"]?.isArchived == true }
        XCTAssertEqual(app.threads["a"]?.isArchived, true)
        try await waitUntil { app.slidingOff.isEmpty }
        XCTAssertTrue(app.slidingOff.isEmpty)
    }

    func testAFailedArchiveBringsTheRowBack() async throws {
        let app = try await app(archiving: false)
        app.archive("a")
        XCTAssertTrue(app.slidingOff.contains("a"))
        try await waitUntil { app.errorMessage != nil }
        XCTAssertTrue(app.slidingOff.isEmpty)
        XCTAssertEqual(app.threads["a"]?.isArchived, false)
        XCTAssertEqual(app.errorMessage, "Busy")
    }

    func testASwipeHasAlreadySlidIt() async throws {
        let app = try await app(archiving: true)
        app.archive("a", slid: true)
        XCTAssertFalse(app.slidingOff.contains("a"))
        try await waitUntil { app.threads["a"]?.isArchived == true }
        XCTAssertEqual(app.threads["a"]?.isArchived, true)
    }

    func testArchivedElsewhereSlidesBeforeItGoes() async throws {
        let app = try await app(archiving: true)
        app.receiveForTesting(ThreadSummary(id: "a", title: "Fix the build", status: .idle, archivedAt: Date()))
        XCTAssertTrue(app.slidingOff.contains("a"))
        XCTAssertEqual(app.threads["a"]?.isArchived, false, "held while the row slides")
        // Anything newer while it's held is what lands.
        app.receiveForTesting(ThreadSummary(id: "a", title: "Fixed the build", status: .idle, archivedAt: Date()))
        try await waitUntil { app.threads["a"]?.isArchived == true }
        XCTAssertEqual(app.threads["a"]?.title, "Fixed the build")
    }

    func testOtherChangesLandStraightAway() async throws {
        let app = try await app(archiving: true)
        app.receiveForTesting(ThreadSummary(id: "a", title: "Renamed", status: .idle))
        XCTAssertEqual(app.threads["a"]?.title, "Renamed")
        XCTAssertTrue(app.slidingOff.isEmpty)
    }
}

/// Answers threads.update with the thread archived, or with a busy error.
private final class ArchivingTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private let archives: Bool

    init(archives: Bool) { self.archives = archives }

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return }
        let reply: [String: Any]
        if method == "threads.update" && archives {
            let thread: [String: Any] = ["id": params["threadId"] ?? "", "title": "Fix the build", "archivedAt": "2026-10-29T00:00:00Z"]
            reply = ["jsonrpc": "2.0", "id": id, "result": ["thread": thread]]
        } else {
            reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32020, "message": "Busy"]]
        }
        push(try JSONSerialization.data(withJSONObject: reply))
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

    private func push(_ data: Data) {
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
