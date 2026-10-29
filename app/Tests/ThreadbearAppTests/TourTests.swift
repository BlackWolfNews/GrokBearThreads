import AppKit
import XCTest
@testable import Threadbear

/// The first-run tour: which steps it shows, that it only comes up by
/// itself once, and where its card goes.
@MainActor
final class TourTests: XCTestCase {
    private var tour: Tour!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TourTests.\(UUID().uuidString)")
        tour = Tour()
        tour.defaults = defaults
    }

    func testSkipsStepsWhosePartIsntOnScreenButKeepsTheHandsOnOnes() {
        tour.frames = [.threads: CGRect(x: 44, y: 0, width: 300, height: 800),
                       // Gone (onDisappear) or squashed to nothing: skipped too.
                       .permission: .zero]
        tour.start()
        // The hands-on steps bring their part up themselves.
        XCTAssertEqual(tour.shown.map(\.title), ["Welcome to Threadbear", "Threads", "Not now? Hibernate it", "Done with it? Archive it",
                                                 "Move a panel", "Patches", "Your first thread"])
        XCTAssertEqual(tour.step, 0)
    }

    func testOnlyTheReplayCanBeSkipped() {
        tour.startIfNew()
        XCTAssertFalse(tour.skippable, "the first run has no Skip")
        tour.finish()
        tour.start()
        XCTAssertTrue(tour.skippable, "Help's replay does")
    }

    func testHighlightsFallsBackToTheRailIcon() {
        tour.frames = [.highlightsRail: CGRect(x: 1140, y: 40, width: 32, height: 32)]
        tour.start()
        let step = tour.shown.first { $0.title == "Highlights" }
        XCTAssertNotNil(step)
        XCTAssertEqual(step.flatMap(tour.frame(for:)), CGRect(x: 1140, y: 40, width: 32, height: 32))
    }

    func testFinishingOrSkippingStopsItComingBack() {
        tour.startIfNew()
        XCTAssertEqual(tour.step, 0)
        tour.next()
        XCTAssertEqual(tour.step, 1)
        tour.back()
        tour.back()
        XCTAssertEqual(tour.step, 0)
        tour.finish()
        XCTAssertNil(tour.step)
        tour.startIfNew()
        XCTAssertNil(tour.step, "only the first time by itself")
        tour.start()
        XCTAssertEqual(tour.step, 0, "the Help menu still runs it")
    }

    func testNextOnTheLastStepEndsIt() {
        tour.start()
        for _ in tour.shown { tour.next() }
        XCTAssertNil(tour.step)
        XCTAssertTrue(defaults.bool(forKey: Tour.seenKey))
    }

    func testCardGoesBesideItsTargetWhereThereIsRoom() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let card = CGSize(width: 300, height: 150)
        // The sidebar: to its right, level with its middle.
        XCTAssertEqual(Tour.cardOrigin(target: CGRect(x: 44, y: 0, width: 300, height: 800), card: card, bounds: bounds, edges: [.right, .left]),
                       CGPoint(x: 358, y: 325))
        // The Highlights panel on the right: no room right, so left.
        XCTAssertEqual(Tour.cardOrigin(target: CGRect(x: 900, y: 0, width: 300, height: 800), card: card, bounds: bounds, edges: [.right, .left]),
                       CGPoint(x: 586, y: 325))
        // The composer near the bottom: above it, kept inside the window.
        XCTAssertEqual(Tour.cardOrigin(target: CGRect(x: 900, y: 700, width: 290, height: 80), card: card, bounds: bounds, edges: [.above]),
                       CGPoint(x: 888, y: 536))
        // Nowhere fits, or nothing to point at: the middle.
        XCTAssertEqual(Tour.cardOrigin(target: bounds, card: card, bounds: bounds, edges: [.right, .left, .below, .above]),
                       CGPoint(x: 450, y: 325))
        XCTAssertEqual(Tour.cardOrigin(target: nil, card: card, bounds: bounds, edges: [.right]), CGPoint(x: 450, y: 325))
    }
}
