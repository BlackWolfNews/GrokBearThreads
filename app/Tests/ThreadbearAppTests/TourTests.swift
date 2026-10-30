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

    func testLeavesOutClosedPanelsButKeepsWhatTurnsUpAsItGoes() {
        tour.frames = [.threads: CGRect(x: 44, y: 0, width: 300, height: 800),
                       // Gone (onDisappear) or squashed to nothing: as good as closed.
                       .activityBar: .zero]
        tour.start()
        // The views and Highlights are panels that aren't there; the samples'
        // rows, the chips, the composer and Finish setting up turn up later.
        XCTAssertEqual(tour.shown.map(\.title), Tour.steps.map(\.title).filter { $0 != "Your views" && $0 != "Highlights" })
        XCTAssertEqual(tour.step, 0)
    }

    /// Mike, 29 Oct: the first cut's cards were too much to read. One short
    /// sentence a card, and a step per idea.
    func testEveryCardIsOneShortSentence() {
        let ends = try! NSRegularExpression(pattern: #"[.!?](\s|$)"#)
        for step in Tour.steps {
            for text in [step.body, step.doneBody, step.failBody].compactMap({ $0 }) {
                let sentences = ends.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                XCTAssertLessThanOrEqual(sentences, 1, "one sentence: \(text)")
                XCTAssertLessThanOrEqual(text.count, 90, "short: \(text)")
            }
            XCTAssertLessThanOrEqual(step.title.count, 24, "short title: \(step.title)")
        }
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
