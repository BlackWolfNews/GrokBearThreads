import XCTest
@testable import ThreadbearCore

/// A thread's sharing on its summary (docs/protocol.md, "Sharing").
final class ThreadShareTests: XCTestCase {
    private func thread(_ extra: String) throws -> ThreadSummary {
        let json = """
        {"id":"t1","title":"Schema","cwd":"/w/app","accountId":"claude-3","provider":"claude","permissionMode":"full",
         "status":"idle","live":false,"needsYou":false,"createdAt":"2026-10-28T08:00:00Z","updatedAt":"2026-10-28T08:00:00Z",
         "lastActivityAt":"2026-10-28T08:00:00Z","preview":"","lastSeq":4,"lastSeenSeq":4\(extra)}
        """
        return try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
    }

    func testDecodesAndKeepsIt() throws {
        let t = try thread(#","share":{"access":"people","slug":"abc","people":["ann@example.com"],"updatedAt":"2026-10-29T08:00:00Z"}"#)
        XCTAssertEqual(t.share, ThreadShare(access: .people, slug: "abc", people: ["ann@example.com"]))
        XCTAssertTrue(t.share!.isOn)
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(again.share, t.share)
    }

    func testOffAndOddOnes() throws {
        XCTAssertEqual(try thread(#","share":{"access":"off","slug":"abc","people":[]}"#).share?.isOn, false)
        // An access this app doesn't know reads as off rather than shared.
        XCTAssertEqual(try thread(#","share":{"access":"team","slug":"abc","people":[]}"#).share?.access, .off)
        // A malformed one is as good as none, rather than losing the thread.
        XCTAssertNil(try thread(#","share":{"access":"link"}"#).share)
        XCTAssertNil(try thread("").share)
    }
}
