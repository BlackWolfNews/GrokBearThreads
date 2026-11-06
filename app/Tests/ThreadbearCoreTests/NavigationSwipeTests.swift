import XCTest
@testable import ThreadbearCore

final class NavigationSwipeTests: XCTestCase {
    private func swiped(_ moves: [(Double, Double)], allowed: Set<NavigationSwipe.Direction> = [.back, .forward]) -> NavigationSwipe {
        var swipe = NavigationSwipe()
        swipe.begin(allowed: allowed)
        for (dx, dy) in moves { _ = swipe.move(dx: dx, dy: dy) }
        return swipe
    }

    /// Fingers right go back and left go forward, as in Safari, once
    /// they're past the line.
    func testRightGoesBackAndLeftForward() {
        var back = swiped([(8, 0), (60, 0), (60, 0)])
        XCTAssertEqual(back.direction, .back)
        XCTAssertTrue(back.armed)
        XCTAssertEqual(back.end(), .back)
        XCTAssertEqual(back.phase, .idle)

        var forward = swiped([(-8, 0), (-120, 0)])
        XCTAssertEqual(forward.end(), .forward)
    }

    /// The events are ours from the one that decides it, so nothing under
    /// the pointer scrolls as well.
    func testTakesTheEventsOnceItsDecided() {
        var swipe = NavigationSwipe()
        swipe.begin(allowed: [.back])
        XCTAssertFalse(swipe.move(dx: 3, dy: 0), "too small to call yet")
        XCTAssertTrue(swipe.move(dx: 4, dy: 1))
        XCTAssertTrue(swipe.move(dx: 20, dy: 0))
        XCTAssertEqual(swipe.travel, 27)
    }

    /// Short of the line, or brought back, goes nowhere.
    func testShortOrBroughtBackGoesNowhere() {
        var short = swiped([(8, 0), (10, 0), (10, 0), (10, 0), (10, 0)])
        XCTAssertFalse(short.armed)
        XCTAssertEqual(short.end(), nil)

        var back = swiped([(8, 0), (150, 0), (-100, 0), (-3, 0)])
        XCTAssertFalse(back.armed)
        XCTAssertEqual(back.end(), nil)
    }

    /// A quick flick goes even short of the line.
    func testFlickGoes() {
        var swipe = swiped([(8, 0), (30, 0), (20, 0)])
        XCTAssertFalse(swipe.armed)
        XCTAssertEqual(swipe.end(), .back)
    }

    /// Up and down is a scroll, and across with nowhere to go that way
    /// (nothing to go forward to, or a row's archive swipe) is left alone.
    func testScrollsAndWaysWithNowhereToGoAreLeftAlone() {
        var scroll = swiped([(2, -8), (200, 0)])
        XCTAssertEqual(scroll.phase, .ignoring)
        XCTAssertEqual(scroll.end(), nil)

        var nowhere = swiped([(-8, 0), (-200, 0)], allowed: [.back])
        XCTAssertEqual(nowhere.phase, .ignoring)
        XCTAssertEqual(nowhere.end(), nil)
    }

    /// The same rule as a row, so the two decide on the same event: a
    /// slightly diagonal scroll still scrolls.
    func testDiagonalScrolls() {
        XCTAssertEqual(swiped([(7, 6)]).phase, .ignoring)
    }

    func testProgressRunsFromNothingToTheLine() {
        XCTAssertEqual(swiped([(8, 0)]).progress, 8 / NavigationSwipe.threshold, accuracy: 0.001)
        XCTAssertEqual(swiped([(8, 0), (400, 0)]).progress, 1)
        XCTAssertEqual(swiped([(2, -8)]).progress, 0)
    }
}
