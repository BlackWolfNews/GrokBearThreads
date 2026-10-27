import XCTest
@testable import ThreadbearCore

final class ThreadRefsTests: XCTestCase {
    func words(_ text: String) -> [String] {
        let string = text as NSString
        return ThreadRefs.candidates(in: text).map { string.substring(with: $0) }
    }

    func testFindsPrefixesAndWholeIds() {
        XCTAssertEqual(words("`85735a8f` (subagents) and 1d827b8c."), ["85735a8f", "1d827b8c"])
        XCTAssertEqual(words("thread 52594bb9-e49d-4ec7-8ed8-bbc61b48ef77 is this one"), ["52594bb9-e49d-4ec7-8ed8-bbc61b48ef77"])
        XCTAssertEqual(words("(85735a8f)"), ["85735a8f"])
    }

    /// Commits are 7 characters, longer hashes and paths aren't ids, and
    /// uppercase hex isn't how the runner writes them.
    func testSkipsWhatIsntAnId() {
        XCTAssertEqual(words("merged d1ecf9c as baa45b6"), [])
        XCTAssertEqual(words("sha 1e66c6d4f2a8b9c0"), [])
        XCTAssertEqual(words("releases/20261027T055446Z-d1ecf9c"), [])
        XCTAssertEqual(words("app/.fixtures/threads/85735a8f"), [])
        XCTAssertEqual(words("x85735a8f 85735a8fx 85735A8F"), [])
    }

    func testIndexResolvesUniquePrefixes() {
        let index = ThreadRefs.Index([
            "52594bb9-e49d-4ec7-8ed8-bbc61b48ef77",
            "85735a8f-0000-4000-8000-000000000001",
            "aaaaaaaa-0000-4000-8000-000000000001",
            "aaaaaaaa-0000-4000-8000-000000000002",
        ])
        XCTAssertEqual(index.resolve("52594bb9"), "52594bb9-e49d-4ec7-8ed8-bbc61b48ef77")
        XCTAssertEqual(index.resolve("52594bb9-e49d-4ec7-8ed8-bbc61b48ef77"), "52594bb9-e49d-4ec7-8ed8-bbc61b48ef77")
        XCTAssertEqual(index.resolve("85735a8f"), "85735a8f-0000-4000-8000-000000000001")
        XCTAssertNil(index.resolve("aaaaaaaa"), "two threads share it")
        XCTAssertEqual(index.resolve("aaaaaaaa-0000-4000-8000-000000000002"), "aaaaaaaa-0000-4000-8000-000000000002")
        XCTAssertNil(index.resolve("1d827b8c"))
    }

    func testDetail() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var thread = ThreadSummary(id: "t", title: "Subagents", cwd: "/Users/m/dev/me/threadbear", status: .running,
                                   lastActivityAt: now.addingTimeInterval(-245))
        XCTAssertEqual(ThreadRefs.detail(thread, account: "claude-2", now: now), "threadbear · claude-2 · Working 4m")
        thread.status = .idle
        XCTAssertEqual(ThreadRefs.status(thread, now: now), "Active 4m ago")
        thread.lastActivityAt = now.addingTimeInterval(-20)
        XCTAssertEqual(ThreadRefs.status(thread, now: now), "Active just now")
        thread.status = .waiting
        XCTAssertEqual(ThreadRefs.detail(thread, account: nil, now: now), "threadbear · Needs you")
        thread.archivedAt = now
        XCTAssertEqual(ThreadRefs.status(thread, now: now), "Archived")
    }
}
