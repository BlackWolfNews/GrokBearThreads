import Foundation
import XCTest
@testable import ThreadbareCore

/// End to end over a real WebSocket: starts Tools/mock-runner (which speaks
/// docs/protocol.md) in a temp data folder and drives it with the real
/// `WebSocketTransport` and `RPCClient`. Skipped when node or the mock's
/// `ws` dependency isn't installed (`npm install` in Tools/mock-runner).
final class MockRunnerTests: XCTestCase {
    private var process: Process?
    private var dataDir: URL!

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() async throws {
        let mock = Self.appRoot.appendingPathComponent("Tools/mock-runner")
        guard FileManager.default.fileExists(atPath: mock.appendingPathComponent("node_modules/ws").path) else {
            throw XCTSkip("Tools/mock-runner has no node_modules; run npm install there")
        }
        guard let node = Self.findNode() else { throw XCTSkip("node isn't on PATH") }
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-mock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        // Only the committed synthetic fixtures, never the private ones.
        process.arguments = [mock.appendingPathComponent("server.mjs").path, "--data-dir", dataDir.path,
                             "--fixtures", mock.appendingPathComponent("fixtures").path, "--quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let runnerJSON = dataDir.appendingPathComponent("runner.json")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: runnerJSON.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: runnerJSON.path) else {
            throw XCTSkip("the mock runner didn't start")
        }
    }

    override func tearDown() async throws {
        process?.terminate()
        process?.waitUntilExit()
        if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
    }

    private static func findNode() -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.nvm/versions/node/v24.22.1/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return paths.map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func connect() async throws -> RPCClient {
        let endpoint = try RunnerConfig.endpoint(dataDir: dataDir)
        let client = RPCClient(transport: WebSocketTransport(url: endpoint.url, token: endpoint.token))
        try await client.start()
        return client
    }

    func testHelloListSearchAndEvents() async throws {
        let client = try await connect()
        defer { client.close() }
        let hello = try await client.hello(version: "test")
        XCTAssertEqual(hello.protocol, 1)
        XCTAssertFalse(hello.accounts.isEmpty)

        let inbox = try await client.listThreads()
        XCTAssertTrue(inbox.contains { $0.id == "demo_upload_resume" })
        XCTAssertFalse(inbox.contains { $0.isArchived }, "archived threads stay out of the inbox")
        let archived = try await client.listThreads(include: [.archived])
        XCTAssertTrue(archived.allSatisfy(\.isArchived))
        XCTAssertFalse(archived.isEmpty)

        let found = try await client.searchThreads("tunnel")
        XCTAssertEqual(found.first?.id, "demo_tunnel", "search covers archived threads too")

        let page = try await client.events(threadId: "demo_upload_resume")
        let model = TranscriptModel(events: page.events)
        let kinds = Set(model.items.map(\.kind))
        for kind in [RowKind.user, .assistant, .reasoning, .tool, .diff, .images, .plan, .approval, .footer] {
            XCTAssertTrue(kinds.contains(kind), "demo thread should have a \(kind) item")
        }
        // Its turns fold their work into groups and end with a changes card.
        let shown = Set(model.rows.map(\.kind))
        XCTAssertTrue(shown.contains(.group))
        XCTAssertTrue(shown.contains(.changes))
        // Image paths come back absolute so the app can read them.
        let images = page.events.flatMap { event -> [ImageRef] in
            if case .toolResult(let result) = event.payload { return result.images }
            return []
        }
        XCTAssertFalse(images.isEmpty)
        XCTAssertTrue(images.allSatisfy { $0.path.hasPrefix("/") && FileManager.default.fileExists(atPath: $0.path) })

        do {
            _ = try await client.events(threadId: "nope")
            XCTFail("expected thread not found")
        } catch RPCError.server(let code, _) {
            XCTAssertEqual(code, RPCError.threadNotFound)
        }
    }

    func testSendStreamsIntoTheFeed() async throws {
        let client = try await connect()
        defer { client.close() }
        _ = try await client.hello(version: "test")
        let threadId = "demo_dark_mode"
        let page = try await client.events(threadId: threadId)
        var feed = ThreadFeed(model: TranscriptModel(events: page.events))
        feed.beginSubscribe()
        let subscribed = try await client.subscribe(threadId: threadId, afterSeq: feed.acceptedSeq)
        _ = feed.finishSubscribe(subscribed.events, inProgress: subscribed.inProgress)

        _ = try await client.send(threadId: threadId, text: "Make the header sticky too")
        var sawDelta = false
        var done = false
        let deadline = Date().addingTimeInterval(15)
        for await notification in client.notifications {
            guard case .threadEvent(let id, let event) = notification, id == threadId else { continue }
            if event.isTransient { sawDelta = true }
            switch feed.receive(event) {
            case .needsCatchUp(let after):
                _ = feed.catchUp(try await client.events(threadId: threadId, afterSeq: after).events)
            default:
                break
            }
            _ = feed.flush()
            if case .turnCompleted = event.payload { done = true }
            if done || Date() > deadline { break }
        }
        XCTAssertTrue(done, "the turn should finish")
        XCTAssertTrue(sawDelta, "the reply should stream as deltas first")
        let rows = feed.model.rows
        XCTAssertTrue(rows.contains { row in
            if case .user(let message) = row.content { return message.text == "Make the header sticky too" }
            return false
        })
        let reply = rows.last { $0.kind == .assistant }
        guard case .assistant(let item)? = reply?.content else { return XCTFail("no reply row") }
        XCTAssertTrue(item.text.contains("mock runner"))
        XCTAssertFalse(item.isStreaming, "the persisted text replaces the streamed one")
        XCTAssertEqual(rows.last?.kind, .footer)
    }

    func testArchiveSnoozeAndMediaImport() async throws {
        let client = try await connect()
        defer { client.close() }
        _ = try await client.hello(version: "test")

        let archived = try await client.updateThread("demo_settings_tabs", ThreadUpdate(archived: true))
        XCTAssertTrue(archived.isArchived)
        let inboxAfterArchive = try await client.listThreads()
        XCTAssertFalse(inboxAfterArchive.contains { $0.id == "demo_settings_tabs" })
        let back = try await client.updateThread("demo_settings_tabs", ThreadUpdate(archived: false))
        XCTAssertFalse(back.isArchived)

        let later = Date().addingTimeInterval(3600)
        let snoozed = try await client.updateThread("demo_settings_tabs", ThreadUpdate(snoozedUntil: .some(later)))
        XCTAssertTrue(snoozed.isSnoozed(at: Date()))
        let snoozedList = try await client.listThreads(include: [.snoozed])
        XCTAssertTrue(snoozedList.contains { $0.id == "demo_settings_tabs" })
        let woken = try await client.updateThread("demo_settings_tabs", ThreadUpdate(snoozedUntil: .some(nil)))
        XCTAssertNil(woken.snoozedUntil)

        let png = Self.appRoot.appendingPathComponent("Tools/mock-runner/fixtures/demo-upload-resume/media/upload-times.png")
        let image = try await client.importMedia(path: png.path)
        XCTAssertEqual(image.mediaType, "image/png")
        XCTAssertEqual(image.width, 760)
        XCTAssertEqual(image.height, 420)
        XCTAssertTrue(image.path.hasPrefix(dataDir.appendingPathComponent("inbox").path))
    }

    func testWrongTokenIsUnauthorized() async throws {
        let endpoint = try RunnerConfig.endpoint(dataDir: dataDir)
        let client = RPCClient(transport: WebSocketTransport(url: endpoint.url, token: "not-the-token"))
        do {
            try await client.start()
            _ = try await client.hello(version: "test")
            XCTFail("a wrong token should be refused")
        } catch let error as RPCError {
            XCTAssertEqual(error, .unauthorized)
        }
        client.close()
    }
}
