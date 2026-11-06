import XCTest
@testable import Threadbear

/// Deciding from a gesture's first few points whether it's a page swipe
/// (AppKit's tracking takes it from there) or a scroll.
final class SwipeStartTests: XCTestCase {
    private func decide(_ moves: [(Double, Double)], allowed: Set<SwipeNavigation.Direction> = [.back, .forward], hold: Bool = true) -> [SwipeStart.Verdict] {
        var start = SwipeStart()
        start.begin(allowed: allowed, hold: hold)
        return moves.map { start.move(dx: $0.0, dy: $0.1, ended: false) }
    }

    func testAcrossIsASwipeWithinAFewPoints() {
        XCTAssertEqual(decide([(2, 0), (4, 1)]), [.wait, .swipe(.back)])
        XCTAssertEqual(decide([(-3, 0), (-3, 0)]), [.wait, .swipe(.forward)])
    }

    /// A real swipe drifts up or down a little: still a swipe, as long as
    /// it's more across than up and down. The first try wanted it half as
    /// much again across, and a long thread scrolled instead (6 Nov).
    func testASwipeThatDriftsIsStillASwipe() {
        XCTAssertEqual(decide([(2, 1), (2, 1), (2, 1)]).last, .swipe(.back))
    }

    /// Ordinary scrolling never waits: more up and down than across goes
    /// straight to the scroll view.
    func testUpAndDownScrollsAtOnce() {
        XCTAssertEqual(decide([(0, 3)]), [.scroll])
        XCTAssertEqual(decide([(1, -2)]), [.scroll])
    }

    func testASidewaysStartThatTurnsIntoAScrollScrolls() {
        XCTAssertEqual(decide([(2, 0), (1, 4)]), [.wait, .scroll])
    }

    func testNowhereToGoThatWayScrolls() {
        XCTAssertEqual(decide([(-6, 0)], allowed: [.back]), [.scroll])
        XCTAssertEqual(decide([(6, 0)], allowed: []), [.scroll])
    }

    func testLiftingBeforeItsDecidedScrolls() {
        var start = SwipeStart()
        start.begin(allowed: [.back], hold: true)
        XCTAssertEqual(start.move(dx: 2, dy: 0, ended: false), .wait)
        XCTAssertEqual(start.move(dx: 0, dy: 0, ended: true), .scroll)
    }

    /// Over a row nothing's held back, and it decides by the row's own
    /// rule, so a row and Back never both take a gesture.
    func testOverARowItDecidesByTheRowsRule() {
        XCTAssertEqual(decide([(5, 0), (2, 0)], hold: false), [.wait, .swipe(.back)])
        XCTAssertEqual(decide([(4, 3)], hold: false).last, .wait)
        XCTAssertEqual(decide([(4, 3), (1, 1)], hold: false).last, .scroll, "too diagonal for a row")
    }
}
