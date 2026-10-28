import AppKit
import XCTest
@testable import Threadbear

/// The pairing code and the browser's name (Settings › Phone & browser).
final class DevicesAppTests: XCTestCase {
    func testPairingCodeIsDrawnAtTheAskedSize() throws {
        let image = try XCTUnwrap(PairingQR.image("threadbear://pair?url=https%3A%2F%2Fx.convex.cloud&token=tb_0123456789abcdef", side: 220))
        XCTAssertGreaterThan(image.size.width, 150)
        XCTAssertLessThanOrEqual(image.size.width, 220)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func testBrowserNamesDropGoogle() {
        XCTAssertEqual(DefaultBrowser.shortName("Google Chrome"), "Chrome")
        XCTAssertEqual(DefaultBrowser.shortName("Safari"), "Safari")
        XCTAssertEqual(DefaultBrowser.shortName("  "), "Browser")
    }
}
