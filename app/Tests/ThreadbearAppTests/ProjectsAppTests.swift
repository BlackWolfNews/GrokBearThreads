import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

@MainActor
final class ProjectsAppTests: XCTestCase {
    private func app(answering answer: @escaping @Sendable (String) -> [String: Any]) async throws -> AppModel {
        let app = AppModel()
        app.notificationsEnabled = false
        let client = RPCClient(transport: AnsweringTransport(answer: answer))
        try await client.start()
        app.useClientForTesting(client)
        return app
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A runner from before projects answers -32601: nothing about
    /// projects shows, and a view of them left open goes back to the inbox.
    func testAnOlderRunnerHidesProjects() async throws {
        let app = try await app { _ in ["error": ["code": -32601, "message": "Unknown method"]] }
        app.projectsSupported = true
        app.sidebarMode = .librarian
        app.loadProjects()
        try await waitFor { app.sidebarMode == .inbox }
        XCTAssertFalse(app.projectsSupported)
        XCTAssertEqual(app.sidebarMode, .inbox)
        XCTAssertNil(app.librarian)
    }

    /// The list and the librarian load; a project's page opens over the
    /// thread, picking a thread closes it, and so does the project going.
    func testLoadingAndThePage() async throws {
        let app = try await app { method in
            switch method {
            case "projects.list":
                return ["result": ["projects": [["id": "p_a", "title": "Threadbear"], ["id": "p_b", "title": "Poddle", "archived": true]]]]
            case "librarian.status":
                return ["result": ["librarian": ["state": "working", "paused": false, "queue": [["threadId": "th1", "reason": "moved"]], "recent": [],
                                                 "current": ["threadId": "th2", "threadTitle": "Two"]]]]
            default:
                return ["error": ["code": -32000, "message": "no"]]
            }
        }
        app.loadProjects()
        try await waitFor { app.librarian != nil }
        XCTAssertTrue(app.projectsSupported)
        XCTAssertEqual(app.projects.map(\.id), ["p_a", "p_b"])
        XCTAssertEqual(app.librarian?.pendingCount, 2, "the badge counts the look under way and the queue")

        app.threads["th1"] = ThreadSummary(id: "th1", title: "One", projects: [ThreadProject(id: "p_a", title: "Threadbear")])
        XCTAssertEqual(app.projectSections.sections.map(\.project.id), ["p_a"], "archived projects aren't in the view")
        XCTAssertEqual(app.projectsToAdd(app.threads["th1"]!).map(\.id), [], "not the one it's in, nor an archived one")

        app.openProjectPage("p_a")
        XCTAssertEqual(app.openProject?.title, "Threadbear")
        app.openProjectPage("p_nope")
        XCTAssertEqual(app.openProjectId, "p_a", "an unknown id leaves the page as it is")
        app.select("th1")
        XCTAssertNil(app.openProjectId, "picking a thread shows the thread")

        app.openProjectPage("p_a")
        app.receive(projects: [Project(id: "p_b", title: "Poddle")])
        XCTAssertNil(app.openProjectId, "merged away or deleted: the page closes")
    }
}

/// Answers each request with what `answer` gives for its method (a
/// `result` or an `error`).
private final class AnsweringTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private let answer: @Sendable (String) -> [String: Any]

    init(answer: @escaping @Sendable (String) -> [String: Any]) {
        self.answer = answer
    }

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        var reply = answer(method)
        reply["jsonrpc"] = "2.0"
        reply["id"] = id
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
