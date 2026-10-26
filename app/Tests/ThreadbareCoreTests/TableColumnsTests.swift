import XCTest
@testable import ThreadbareCore

final class TableColumnsTests: XCTestCase {
    func testColumnsThatFitKeepTheirWidths() {
        XCTAssertEqual(TableColumns.fit([80, 120, 200], into: 700), [80, 120, 200])
    }

    /// The long column takes what the short ones leave, rather than every
    /// column shrinking by the same share.
    func testOneWideColumnTakesTheRest() {
        XCTAssertEqual(TableColumns.fit([80, 120, 1200], into: 700), [80, 120, 500])
    }

    func testTwoWideColumnsShareTheRest() {
        XCTAssertEqual(TableColumns.fit([100, 900, 1200], into: 700), [100, 300, 300])
    }

    func testEverythingTooWideSharesEqually() {
        XCTAssertEqual(TableColumns.fit([400, 500, 600], into: 600), [200, 200, 200])
    }

    func testEmptyAndZeroBudget() {
        XCTAssertEqual(TableColumns.fit([], into: 700), [])
        XCTAssertEqual(TableColumns.fit([50, 60], into: 0), [50, 60])
    }
}
