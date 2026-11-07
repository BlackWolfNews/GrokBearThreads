import Foundation
import Testing
@testable import ThreadbearKit

/// What makes the inbox animate: a thread changing heading is news, so its row
/// glides. A title or a working line changing isn't, or a busy inbox would never
/// sit still under his thumb.
@Suite struct InboxMovesTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func thread(_ id: String, status: ThreadStatus = .idle, working: String? = nil, starred: Bool = false, title: String? = nil, ago: Double = 60) -> PhoneThread {
        PhoneThread(threadId: id, title: title ?? id, status: status, lastActivityAt: now.addingTimeInterval(-ago),
                    starredAt: starred ? now : nil, working: working)
    }
    private func sections(_ threads: PhoneThread...) -> InboxSections { InboxSections.build(threads, now: now) }

    @Test func aFinishedTurnMovesFromRunningToInbox() {
        let before = sections(thread("a", status: .running, working: "Running npm test"), thread("b"))
        let after = sections(thread("a"), thread("b"))
        #expect(before.changedHeadings(to: after))
    }

    @Test func aStarElsewhereMoves() {
        #expect(sections(thread("a")).changedHeadings(to: sections(thread("a", starred: true))))
    }

    @Test func aThreadTurningUpOrLeavingCounts() {
        #expect(sections(thread("a")).changedHeadings(to: sections(thread("a"), thread("b"))))
        #expect(sections(thread("a"), thread("b")).changedHeadings(to: sections(thread("a"))))
    }

    @Test func aFieldChangingStaysStill() {
        let before = sections(thread("a", status: .running, working: "Running npm test"), thread("b"))
        let after = sections(thread("a", status: .running, working: "Reading a file", title: "A new title"), thread("b", ago: 5))
        #expect(!before.changedHeadings(to: after))
    }

    @Test func aReorderInsideAHeadingStaysStill() {
        let before = sections(thread("a", ago: 10), thread("b", ago: 20))
        let after = sections(thread("a", ago: 30), thread("b", ago: 20))
        #expect(before.inbox.map(\.threadId) != after.inbox.map(\.threadId))
        #expect(!before.changedHeadings(to: after))
    }
}
