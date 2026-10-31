import XCTest
@testable import Threadbear

/// What `DragSpace` takes a window off: any Space no display has, which on
/// macOS 27.2 is the drag Space a drag can leave the window on, hiding every
/// menu opened from it (1 Nov). Spaces as on Mike's Mac: 1 on the laptop,
/// 122 and 123 on the two monitors, 31 the drag Space.
final class DragSpaceTests: XCTestCase {
    let displays: Set<Int> = [1, 122, 123]

    func testAWindowLeftOnTheDragSpaceComesOffIt() {
        XCTAssertEqual(DragSpace.strays(windowSpaces: [31, 122], displaySpaces: displays), [31])
    }

    func testAWindowOnlyOnItsDisplaysSpaceIsLeftAlone() {
        XCTAssertEqual(DragSpace.strays(windowSpaces: [122], displaySpaces: displays), [])
        XCTAssertEqual(DragSpace.strays(windowSpaces: [], displaySpaces: displays), [])
    }

    /// Taken off, the window server puts it back on its display's Space
    /// (checked with a test app).
    func testAWindowOnlyOnTheDragSpaceComesOffItToo() {
        XCTAssertEqual(DragSpace.strays(windowSpaces: [31], displaySpaces: displays), [31])
    }

    /// A full-screen app's Space is a display's own, so it's never touched.
    func testAFullScreenSpaceIsADisplaysOwn() {
        XCTAssertEqual(DragSpace.strays(windowSpaces: [130], displaySpaces: displays.union([130])), [])
    }
}
