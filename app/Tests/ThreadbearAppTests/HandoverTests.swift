import AppKit
import XCTest
@testable import Threadbear

final class HandoverTests: XCTestCase {
    func testArgumentsKeepTheAppsOwnAndReplaceAnEarlierHandovers() {
        let frame = NSRect(x: 10, y: 20, width: 1180, height: 800)
        let first = Handover.arguments(current: ["--data-dir", "/tmp/d"], outgoingPid: 42, windowNumber: 7, frame: frame)
        XCTAssertEqual(Array(first.prefix(2)), ["--data-dir", "/tmp/d"])
        XCTAssertEqual(Handover.value(after: Handover.fromFlag, in: first), 42)
        XCTAssertEqual(Handover.value(after: Handover.belowFlag, in: first), 7)
        XCTAssertEqual(Handover.string(after: Handover.frameFlag, in: first).map(NSRectFromString), frame)
        // The incoming app hands over again at the next update: one set of
        // handover arguments, its own.
        let second = Handover.arguments(current: first, outgoingPid: 43, windowNumber: 8, frame: frame)
        XCTAssertEqual(second.filter { $0 == Handover.fromFlag }.count, 1)
        XCTAssertEqual(second.filter { $0 == Handover.frameFlag }.count, 1)
        XCTAssertEqual(Handover.value(after: Handover.fromFlag, in: second), 43)
        XCTAssertEqual(Array(second.prefix(2)), ["--data-dir", "/tmp/d"])
    }

    func testValueAfterAFlagWithNothingAfterIt() {
        XCTAssertNil(Handover.value(after: Handover.fromFlag, in: ["--handover-from"]))
        XCTAssertNil(Handover.value(after: Handover.fromFlag, in: []))
    }

    func testOnlyAWindowPlainlyOnScreenIsHandedOver() {
        XCTAssertTrue(Handover.canHandOver(visible: true, miniaturized: false, fullScreen: false, appHidden: false))
        XCTAssertFalse(Handover.canHandOver(visible: false, miniaturized: false, fullScreen: false, appHidden: false))
        XCTAssertFalse(Handover.canHandOver(visible: true, miniaturized: true, fullScreen: false, appHidden: false))
        XCTAssertFalse(Handover.canHandOver(visible: true, miniaturized: false, fullScreen: true, appHidden: false))
        XCTAssertFalse(Handover.canHandOver(visible: true, miniaturized: false, fullScreen: false, appHidden: true))
    }

    func testTheIncomingAppShowsOnceLoadedOrAfterWaitingLongEnough() {
        XCTAssertTrue(Handover.loaded(threadsLoaded: true, connected: true, selectionLoaded: true, waited: 0.5))
        XCTAssertFalse(Handover.loaded(threadsLoaded: true, connected: true, selectionLoaded: false, waited: 0.5))
        XCTAssertFalse(Handover.loaded(threadsLoaded: false, connected: true, selectionLoaded: true, waited: 0.5))
        XCTAssertFalse(Handover.loaded(threadsLoaded: true, connected: false, selectionLoaded: true, waited: 0.5))
        // A runner that's down: shown anyway, rather than never.
        XCTAssertTrue(Handover.loaded(threadsLoaded: false, connected: false, selectionLoaded: false, waited: Handover.loadTimeout))
    }

    func testAnOrdinaryLaunchIsNotAnIncomingApp() {
        XCTAssertNil(Handover.incomingFrom)
    }
}
