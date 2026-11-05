import Foundation
import Testing
@testable import ThreadbearKit

/// The inbox followed by its changes (backend API 42).
@Suite struct InboxChangesTests {
    private func thread(_ id: String, _ activity: Double) -> [String: Any] {
        ["threadId": id, "runnerId": "r", "title": id, "cwd": "/x", "accountId": "a", "provider": "claude", "status": "idle",
         "needsYou": false, "unread": false, "preview": "", "createdAt": "2026-11-05T00:00:00Z",
         "lastActivityAt": "2026-11-05T00:00:0\(Int(activity))Z", "lastActivityMs": activity, "view": "inbox"]
    }
    private func decode<T: Decodable>(_ json: [String: Any], as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func changesMergeIntoTheListNewestFirst() throws {
        let start = try decode(["rows": [thread("a", 2), thread("b", 1), thread("c", 0)], "at": 10_000], as: ThreadsAtAnswer.self)
        var list = InboxChanges(rows: start.rows, at: start.at)
        #expect(list.since == 5000)
        var moved = thread("c", 3)
        moved["updatedMs"] = 20_000
        var archived = thread("a", 2)
        archived["view"] = "den"
        archived["updatedMs"] = 15_000
        list.merge(try decode(["rows": [moved, archived], "gone": ["b"]], as: ThreadsSinceAnswer.self))
        #expect(list.rows.map(\.threadId) == ["c"])
        #expect(list.since == 15_000)
        // Nothing newer: it stays where it is, so no new subscription.
        list.merge(try decode(["rows": [moved], "gone": []], as: ThreadsSinceAnswer.self))
        #expect(list.since == 15_000)
    }

    @Test func aBackendTooOldKeepsTheWholeList() {
        #expect(BackendCompatibility.threadChangesAPIVersion > BackendCompatibility.secretsAPIVersion)
    }
}
