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

    // Filing: the window sits on the LG (Space 122), and the laptop (1) and
    // the other monitor (123) are the other displays.

    /// As an update restart in the background left it, 1 Nov: on the LG but
    /// filed under the laptop's Space. Taken off that, it lands on the LG's.
    func testAWindowFiledUnderAnotherDisplaysSpaceComesOffIt() {
        XCTAssertEqual(DragSpace.misfiled(windowSpaces: [1], own: [122], others: [1, 123]), [1])
    }

    func testAWindowFiledUnderItsOwnDisplayIsLeftAlone() {
        XCTAssertEqual(DragSpace.misfiled(windowSpaces: [122], own: [122], others: [1, 123]), [])
    }

    /// Mike put it on another of the LG's Desktops: it stays there.
    func testAWindowOnAnotherOfItsOwnDisplaysDesktopsIsLeftAlone() {
        XCTAssertEqual(DragSpace.misfiled(windowSpaces: [124], own: [122, 124], others: [1, 123]), [])
    }

    /// On its own display's Space as well, nothing's wrong with where it is.
    func testAWindowAlsoOnItsOwnDisplaysSpaceIsLeftAlone() {
        XCTAssertEqual(DragSpace.misfiled(windowSpaces: [1, 122], own: [122], others: [1, 123]), [])
    }

    /// Only on the drag Space (no display's), it's the drag Space repair's.
    func testADragSpaceIsntAnotherDisplays() {
        XCTAssertEqual(DragSpace.misfiled(windowSpaces: [31], own: [122], others: [1, 123]), [])
    }
}
