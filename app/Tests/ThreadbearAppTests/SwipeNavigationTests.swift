import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// Trackpad swipes through the event path the window's monitor uses, with
/// made-up scroll events (RowSwipeEvents).
@MainActor
final class SwipeNavigationTests: XCTestCase {
    private var window: NSWindow!
    private var saved: NSWindow?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        saved = MainWindowFrame.window
        MainWindowFrame.window = window
    }

    override func tearDown() {
        MainWindowFrame.window = saved
        super.tearDown()
    }

    private func settle() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private func app() async -> AppModel {
        let app = AppModel()
        app.notificationsEnabled = false
        for id in ["a", "b"] { app.threads[id] = ThreadSummary(id: id, title: id) }
        app.select("a")
        await settle()
        app.select("b")
        await settle()
        return app
    }

    private func swipeNavigation(_ app: AppModel, on: Bool = true) -> SwipeNavigation {
        let swipes = SwipeNavigation()
        swipes.app = app
        swipes.scrollSwipesOn = { on }
        return swipes
    }

    /// Fingers' way, right positive; returns what each event was taken as.
    @discardableResult
    private func swipe(_ swipes: SwipeNavigation, _ moves: [Double]) -> [Bool] {
        var taken: [Bool] = []
        for (i, dx) in moves.enumerated() {
            let phase: RowSwipeEvents.Phase = i == 0 ? .began : .changed
            guard let event = RowSwipeEvents.event(dx: dx, phase: phase) else { XCTFail("no event"); return taken }
            taken.append(swipes.handle(event, in: window))
        }
        if let end = RowSwipeEvents.event(dx: 0, phase: .ended) { taken.append(swipes.handle(end, in: window)) }
        return taken
    }

    func testSwipeRightGoesBackAndLeftForward() async {
        let app = await app()
        let swipes = swipeNavigation(app)
        let taken = swipe(swipes, [8, 20, 40, 40, 20])
        XCTAssertEqual(app.selection, "a")
        XCTAssertEqual(taken.first, true, "the deciding event is ours")
        XCTAssertEqual(taken.last, false, "the end is passed on, for a row deciding alongside")
        swipe(swipes, [-8, -20, -40, -40, -20])
        XCTAssertEqual(app.selection, "b")
    }

    func testShortSwipeGoesNowhere() async {
        let app = await app()
        let swipes = swipeNavigation(app)
        swipe(swipes, [8, 10, 10])
        XCTAssertEqual(app.selection, "b")
    }

    /// Nothing to go forward to: a swipe left is left to whatever's under it.
    func testNowhereToGoLeavesTheEventsAlone() async {
        let app = await app()
        let swipes = swipeNavigation(app)
        let taken = swipe(swipes, [-8, -40, -40, -40])
        XCTAssertEqual(taken, [false, false, false, false, false])
        XCTAssertEqual(app.selection, "b")
    }

    /// "Swipe between pages" off in System Settings: scrolling only.
    func testOffInSystemSettings() async {
        let app = await app()
        let swipes = swipeNavigation(app, on: false)
        XCTAssertFalse(swipes.takesBack)
        swipe(swipes, [8, 40, 40, 40])
        XCTAssertEqual(app.selection, "b")
    }

    /// Only the main window's swipes navigate.
    func testOtherWindowsKeepTheirSwipes() async {
        let app = await app()
        let swipes = swipeNavigation(app)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        guard let event = RowSwipeEvents.event(dx: 8, phase: .began) else { return XCTFail("no event") }
        XCTAssertFalse(swipes.handle(event, in: other))
    }
}
