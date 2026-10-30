import Foundation
import XCTest
@testable import ThreadbearCore

/// Another runner's files (docs/protocol.md, "Other runners' threads",
/// `files.read`): both answers decoded, and this Mac's copies fetched once,
/// checked with `known` at most once a launch, and kept bounded.
final class RemoteFilesTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-remote-files-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func decode(_ object: [String: Any]) throws -> FileRead {
        try JSONDecoder().decode(FileRead.self, from: Data(E.json(object).utf8))
    }

    func testDecodesTheBytesAndUnchanged() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2])
        let read = try decode(["path": "/Users/bruce/a.png", "size": 7, "modifiedAt": "2026-10-30T01:02:03.000Z",
                               "mediaType": "image/png", "data": bytes.base64EncodedString(), "truncated": false, "extra": true])
        XCTAssertEqual(read.data, bytes)
        XCTAssertEqual(read.stamp, FileStamp(size: 7, modifiedAt: "2026-10-30T01:02:03.000Z"))
        XCTAssertEqual(read.mediaType, "image/png")
        XCTAssertFalse(read.unchanged)
        XCTAssertFalse(read.truncated)

        let cut = try decode(["path": "/x/big.log", "size": 99, "modifiedAt": "t", "mediaType": "text/plain", "data": "YWJj", "truncated": true])
        XCTAssertTrue(cut.truncated)
        XCTAssertEqual(cut.data, Data("abc".utf8))

        let same = try decode(["path": "/Users/bruce/a.png", "unchanged": true, "size": 7, "modifiedAt": "2026-10-30T01:02:03.000Z"])
        XCTAssertTrue(same.unchanged)
        XCTAssertNil(same.data)
        XCTAssertEqual(same.stamp.size, 7)

        XCTAssertThrowsError(try decode(["path": "/x", "size": 1, "modifiedAt": "t"]), "neither bytes nor unchanged")
        XCTAssertThrowsError(try decode(["path": "/x", "size": 1, "modifiedAt": "t", "data": "not base64!"]))
    }

    func testReadFileSendsKnownAndDecodesTheAnswer() async throws {
        let transport = FakeTransport()
        transport.onSend = { request in
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any] = params["known"] != nil
                ? ["path": params["path"]!, "unchanged": true, "size": 3, "modifiedAt": "m"]
                : ["path": params["path"]!, "size": 3, "modifiedAt": "m", "mediaType": "text/plain", "data": "YWJj", "truncated": false]
            return [E.json(["jsonrpc": "2.0", "id": request["id"]!, "result": result])]
        }
        let client = RPCClient(transport: transport)
        try await client.start()
        let first = try await client.readFile(path: "/Volumes/CannMedia/list.txt")
        XCTAssertEqual(first.data, Data("abc".utf8))
        let again = try await client.readFile(path: "/Volumes/CannMedia/list.txt", known: first.stamp)
        XCTAssertTrue(again.unchanged)
        let sent = transport.sent
        XCTAssertEqual(sent.map { $0["method"] as? String }, ["files.read", "files.read"])
        XCTAssertNil((sent[0]["params"] as? [String: Any])?["known"])
        let known = (sent[1]["params"] as? [String: Any])?["known"] as? [String: Any]
        XCTAssertEqual(known?["size"] as? Int, 3)
        XCTAssertEqual(known?["modifiedAt"] as? String, "m")
    }

    /// What the runner would answer for a file of `content` last changed at
    /// `modifiedAt`, recording each `known` it was asked with.
    private final class FakeRunnerFile: @unchecked Sendable {
        var content: Data
        var modifiedAt: String
        var asked: [FileStamp?] = []
        var failing: Error?

        init(_ text: String, modifiedAt: String = "2026-10-30T00:00:00.000Z") {
            content = Data(text.utf8)
            self.modifiedAt = modifiedAt
        }

        func read(_ known: FileStamp?) throws -> FileRead {
            asked.append(known)
            if let failing { throw failing }
            let stamp = FileStamp(size: content.count, modifiedAt: modifiedAt)
            if known == stamp { return FileRead(path: "/x", stamp: stamp, unchanged: true) }
            return FileRead(path: "/x", stamp: stamp, mediaType: "text/plain", data: content)
        }
    }

    func testFetchedOnceAndCheckedWithKnownOncePerLaunch() async throws {
        let file = FakeRunnerFile("first")
        let path = "/Users/bruce/notes/duplicates.txt"
        let launch1 = RemoteFileCache(root: root)
        let copy = try await launch1.copy(runnerId: "r-bruce", path: path, read: file.read)
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "first")
        XCTAssertEqual(copy.url.lastPathComponent, "duplicates.txt", "named as the file, so it opens in the same viewer")
        XCTAssertEqual(file.asked, [nil], "fetched whole the first time")
        XCTAssertEqual(launch1.ready(runnerId: "r-bruce", path: path)?.url, copy.url)

        _ = try await launch1.copy(runnerId: "r-bruce", path: path, read: file.read)
        XCTAssertEqual(file.asked.count, 1, "not asked again in the same launch")
        XCTAssertNil(launch1.ready(runnerId: "r-other", path: path), "each runner's files are its own")

        // The next launch: the copy is there but asked about once, with
        // what it knows, and an unchanged answer keeps it.
        let launch2 = RemoteFileCache(root: root)
        XCTAssertNil(launch2.ready(runnerId: "r-bruce", path: path), "not used unchecked")
        XCTAssertEqual(launch2.plan(runnerId: "r-bruce", path: path), .check(FileStamp(size: 5, modifiedAt: file.modifiedAt)))
        let kept = try await launch2.copy(runnerId: "r-bruce", path: path, read: file.read)
        XCTAssertEqual(file.asked.last, FileStamp(size: 5, modifiedAt: file.modifiedAt))
        XCTAssertEqual(try String(contentsOf: kept.url, encoding: .utf8), "first")
        _ = try await launch2.copy(runnerId: "r-bruce", path: path, read: file.read)
        XCTAssertEqual(file.asked.count, 2, "once per launch")

        // Changed on that Mac since: the new bytes replace the copy.
        file.content = Data("second!".utf8)
        file.modifiedAt = "2026-10-30T09:00:00.000Z"
        let launch3 = RemoteFileCache(root: root)
        let fresh = try await launch3.copy(runnerId: "r-bruce", path: path, read: file.read)
        XCTAssertEqual(try String(contentsOf: fresh.url, encoding: .utf8), "second!")
        XCTAssertEqual(fresh.stamp.size, 7)
    }

    func testUnchangedForACopyThatWentIsFetchedWhole() async throws {
        let file = FakeRunnerFile("hello")
        let launch1 = RemoteFileCache(root: root)
        let copy = try await launch1.copy(runnerId: "r", path: "/a/b.txt", read: file.read)
        // Asked about with a stamp, but gone by the time the answer comes.
        let launch2 = RemoteFileCache(root: root)
        let stale = FileRead(path: "/a/b.txt", stamp: copy.stamp, unchanged: true)
        try FileManager.default.removeItem(at: copy.url)
        XCTAssertNil(try launch2.store(stale, runnerId: "r", path: "/a/b.txt"))
        XCTAssertEqual(launch2.plan(runnerId: "r", path: "/a/b.txt"), .fetch)
        let again = try await launch2.copy(runnerId: "r", path: "/a/b.txt", read: file.read)
        XCTAssertEqual(try String(contentsOf: again.url, encoding: .utf8), "hello")
        XCTAssertEqual(file.asked.last, .some(nil))
    }

    func testAnOldCopyIsUsedWhenItsMacCantBeReached() async throws {
        let file = FakeRunnerFile("from before")
        _ = try await RemoteFileCache(root: root).copy(runnerId: "r", path: "/a.txt", read: file.read)
        file.failing = RPCError.connectFailed("asleep")
        let copy = try await RemoteFileCache(root: root).copy(runnerId: "r", path: "/a.txt", read: file.read)
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "from before")
        // One the runner says has gone isn't shown.
        file.failing = RPCError.server(code: -32602, message: "No such file: /a.txt")
        do {
            _ = try await RemoteFileCache(root: root).copy(runnerId: "r", path: "/a.txt", read: file.read)
            XCTFail("a file that's gone is an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No such file: /a.txt")
        }
    }

    func testATruncatedFileIsKeptAsCut() async throws {
        let cache = RemoteFileCache(root: root)
        let read = FileRead(path: "/big.log", stamp: FileStamp(size: 100, modifiedAt: "m"), mediaType: "text/plain", data: Data("start".utf8), truncated: true)
        let copy = try await cache.copy(runnerId: "r", path: "/big.log") { _ in read }
        XCTAssertTrue(copy.truncated)
        XCTAssertEqual(cache.ready(runnerId: "r", path: "/big.log")?.truncated, true)
    }

    func testStaysUnderItsCapLeastRecentlyUsedFirst() throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let cache = RemoteFileCache(root: root, maxBytes: 25, maxAge: 86_400, now: { clock.now })
        func store(_ path: String, _ size: Int) throws -> RemoteFileCache.Copy? {
            clock.now += 1
            return try cache.store(FileRead(path: path, stamp: FileStamp(size: size, modifiedAt: "m"), data: Data(count: size)), runnerId: "r", path: path)
        }
        let a = try XCTUnwrap(try store("/a", 10))
        _ = try store("/b", 10)
        clock.now += 1
        XCTAssertNotNil(cache.ready(runnerId: "r", path: "/a"), "a used after b")
        _ = try store("/c", 10)
        XCTAssertNil(cache.ready(runnerId: "r", path: "/b"), "b, used longest ago, went to stay under 25 bytes")
        XCTAssertNotNil(cache.ready(runnerId: "r", path: "/a"))
        XCTAssertNotNil(cache.ready(runnerId: "r", path: "/c"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))

        // Unused for longer than maxAge: gone by the next launch.
        clock.now += 2 * 86_400
        let later = RemoteFileCache(root: root, maxBytes: 25, maxAge: 86_400, now: { clock.now })
        XCTAssertEqual(later.plan(runnerId: "r", path: "/a"), .fetch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }
}
