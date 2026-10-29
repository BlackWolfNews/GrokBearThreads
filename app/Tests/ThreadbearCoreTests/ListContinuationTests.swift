import XCTest
@testable import ThreadbearCore

final class ListContinuationTests: XCTestCase {
    /// Shift-Return with the caret at "|" (or the selection between two of
    /// them): the text afterwards, with the caret where it ends up.
    private func shiftReturn(_ marked: String) -> String {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        let start = (parts[0] as NSString).length
        let length = parts.count > 2 ? (parts[1] as NSString).length : 0
        let selection = NSRange(location: start, length: length)
        let edit = ListContinuation.newline(in: text, selection: selection)
            ?? ListContinuation.Edit(range: selection, text: "\n")
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.range.location + (edit.text as NSString).length, length: 0), with: "|")
    }

    func testNumberedListCountsOn() {
        XCTAssertEqual(shiftReturn("1. milk|"), "1. milk\n2. |")
        XCTAssertEqual(shiftReturn("1. milk\n2. eggs|"), "1. milk\n2. eggs\n3. |")
        XCTAssertEqual(shiftReturn("9) nine|"), "9) nine\n10) |")
    }

    func testBulletsCarryOn() {
        XCTAssertEqual(shiftReturn("- milk|"), "- milk\n- |")
        XCTAssertEqual(shiftReturn("* milk|"), "* milk\n* |")
        XCTAssertEqual(shiftReturn("+ milk|"), "+ milk\n+ |")
    }

    func testIndentAndSpacingAreKept() {
        XCTAssertEqual(shiftReturn("1. a\n   - b|"), "1. a\n   - b\n   - |")
        XCTAssertEqual(shiftReturn("\t-  b|"), "\t-  b\n\t-  |")
    }

    func testCheckboxesStartUnticked() {
        XCTAssertEqual(shiftReturn("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(shiftReturn("- [ ] todo|"), "- [ ] todo\n- [ ] |")
    }

    func testEmptyItemEndsTheList() {
        XCTAssertEqual(shiftReturn("1. milk\n2. |"), "1. milk\n|")
        XCTAssertEqual(shiftReturn("- milk\n  - |"), "- milk\n|")
        XCTAssertEqual(shiftReturn("- [ ] |"), "|")
    }

    func testCaretMidItemSplitsIt() {
        XCTAssertEqual(shiftReturn("1. milk| eggs"), "1. milk\n2. | eggs")
        XCTAssertEqual(shiftReturn("- |milk"), "- \n- |milk")
    }

    func testSelectionIsReplaced() {
        XCTAssertEqual(shiftReturn("1. milk| and eggs|"), "1. milk\n2. |")
    }

    func testOtherLinesAreAPlainNewLine() {
        XCTAssertEqual(shiftReturn("hello|"), "hello\n|")
        XCTAssertEqual(shiftReturn("**bold**|"), "**bold**\n|")
        XCTAssertEqual(shiftReturn("version 2.5|"), "version 2.5\n|")
        XCTAssertEqual(shiftReturn("-no space|"), "-no space\n|")
        XCTAssertEqual(shiftReturn("1. milk\nnot a list|"), "1. milk\nnot a list\n|")
        XCTAssertEqual(shiftReturn(""), "\n|")
    }

    /// The caret inside the marker, or in the indent, isn't in the item yet.
    func testCaretBeforeTheItemIsAPlainNewLine() {
        XCTAssertEqual(shiftReturn("1.| milk"), "1.\n| milk")
        XCTAssertEqual(shiftReturn("  |- milk"), "  \n|- milk")
    }

    func testCountsInUTF16() {
        XCTAssertEqual(shiftReturn("- 🐻 bear|"), "- 🐻 bear\n- |")
        XCTAssertEqual(shiftReturn("🐻\n1. a|"), "🐻\n1. a\n2. |")
    }
}
