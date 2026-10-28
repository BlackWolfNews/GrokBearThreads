import XCTest
@testable import Threadbear

/// A mouse has no two-finger swipe, so dragging a sidebar row left with the
/// button down swipes it too (`RowSwipeController.drag`).
@MainActor
final class RowSwipeDragTests: XCTestCase {
    private var row: RowSwipeController!
    private var ran = false

    override func setUp() async throws {
        ran = false
        row = RowSwipeController()
        row.setWidth(300)
        row.action = RowSwipeAction(icon: "archivebox", run: { [unowned self] in ran = true })
    }

    /// From where the button went down, a few points at a time, as a
    /// steady hand does.
    private func drag(to x: CGFloat, y: CGFloat = 0, step: CGFloat = 5) {
        row.drag(.zero)
        let steps = Int(max(abs(x), abs(y)) / step)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            row.drag(CGSize(width: x * t, height: y * t))
        }
    }

    func testDraggingPastTheLineArchives() async throws {
        drag(to: -150)
        XCTAssertTrue(row.swipe.armed)
        XCTAssertEqual(row.offset, -150)
        row.dragEnded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(ran)
    }

    func testAShortDragSpringsBack() async throws {
        drag(to: -40)
        XCTAssertTrue(row.isSwiping)
        row.dragEnded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(ran)
        XCTAssertEqual(row.offset, 0)
    }

    func testAClickIsJustAClick() {
        row.drag(.zero)
        row.dragEnded()
        XCTAssertFalse(row.isSwiping)
        XCTAssertEqual(row.swipe.phase, .idle)
    }

    func testDraggingDownLeavesTheRowWhereItIs() {
        drag(to: -10, y: 80)
        XCTAssertFalse(row.isSwiping)
        XCTAssertEqual(row.offset, 0)
        row.dragEnded()
        XCTAssertEqual(row.swipe.phase, .idle)
    }

    func testNothingHappensWithoutAnAction() {
        row.action = nil
        drag(to: -150)
        XCTAssertFalse(row.isSwiping)
    }
}
