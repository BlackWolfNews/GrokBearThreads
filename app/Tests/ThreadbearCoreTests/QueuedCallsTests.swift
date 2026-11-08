import XCTest
@testable import ThreadbearCore

/// docs/protocol.md, "Queued calls": a reply's other calls that will ask,
/// shown on the first one's card.
final class QueuedCallsTests: XCTestCase {
    /// By id: once allowed it folds into the work around it.
    private func approval(_ model: TranscriptModel) -> ApprovalItem? {
        if case .approval(let item)? = model.item(id: "ap:ap1")?.content { return item }
        return nil
    }

    func testTheQueueLandsOnItsCardGrowsAndStaysOnceAnswered() {
        var model = TranscriptModel(events: [
            E.user(0, "Fix the tests"),
            E.call(1, "e1", name: "Edit", kind: "edit", title: "Edit a.swift", input: ["file_path": "/r/a.swift"]),
            E.event(2, "approval.requested", ["approvalId": "ap1", "itemId": "e1", "name": "Edit", "title": "Edit a.swift", "input": [:], "options": ["allow", "allowAlways", "deny"]]),
            E.event(3, "approval.queued", ["approvalId": "ap1", "calls": [
                ["itemId": "w1", "name": "Write", "title": "Write b.swift", "input": ["file_path": "/r/b.swift", "content": "x"]],
                // No itemId: dropped rather than answered by a made-up id.
                ["name": "Bash", "title": "ls"],
            ]]),
        ])
        XCTAssertEqual(approval(model)?.queued.map(\.approvalId), ["w1"])
        XCTAssertEqual(approval(model)?.queued.first?.itemId, "w1")
        XCTAssertEqual(approval(model)?.queued.first?.name, "Write")
        _ = model.apply([E.event(4, "approval.queued", ["approvalId": "ap1", "calls": [
            ["itemId": "w1", "name": "Write", "title": "Write b.swift", "input": [:]],
            ["itemId": "b1", "name": "Bash", "title": "rm -rf build", "input": ["command": "rm -rf build"]],
        ]])])
        XCTAssertEqual(approval(model)?.queued.map(\.approvalId), ["w1", "b1"], "a later list replaces it")
        _ = model.apply([E.event(5, "approval.resolved", ["approvalId": "ap1", "decision": "allow"])])
        // A list arriving after the answer doesn't touch the settled line.
        _ = model.apply([E.event(6, "approval.queued", ["approvalId": "ap1", "calls": [["itemId": "z1", "name": "Bash", "title": "ls", "input": [:]]]])])
        XCTAssertEqual(approval(model)?.queued.map(\.approvalId), ["w1", "b1"])
        XCTAssertEqual(approval(model)?.resolution?.decision, .allow)
    }
}
