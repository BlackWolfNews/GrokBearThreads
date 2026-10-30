import AppKit
import XCTest
@testable import Threadbear

/// A review opens in a window covering 90% of the screen, centred, and no
/// bigger than ReviewWindowController.maxSize on a huge display.
@MainActor
final class ReviewWindowFrameTests: XCTestCase {
    func testALaptopScreenGetsNinetyPercentCentred() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = ReviewWindowController.frame(on: visible)
        XCTAssertEqual(frame.width, 1361)
        XCTAssertEqual(frame.height, 850)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 1)
    }

    func testAHugeScreenIsCapped() {
        let visible = NSRect(x: -1000, y: 200, width: 5120, height: 2160)
        let frame = ReviewWindowController.frame(on: visible)
        XCTAssertEqual(frame.size, ReviewWindowController.maxSize)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 1)
    }
}
