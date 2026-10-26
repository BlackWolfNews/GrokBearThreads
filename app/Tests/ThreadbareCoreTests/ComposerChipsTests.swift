import XCTest
@testable import ThreadbareCore

final class ComposerChipsTests: XCTestCase {
    /// The folder chip shows just the folder's own name.
    func testFolderIsTheLastPathComponent() {
        XCTAssertEqual(ComposerChips.folder("/Users/mike/dev/me/misc"), "misc")
        XCTAssertEqual(ComposerChips.folder("/Users/mike/dev/photo-sync/"), "photo-sync")
        XCTAssertEqual(ComposerChips.folder("/"), "/")
        XCTAssertEqual(ComposerChips.folder(""), "Folder")
    }

    /// Nearly every thread is in the default folder, so the chip only shows
    /// for one that isn't. A trailing slash or a ~ doesn't make it differ.
    func testFolderChipOnlyShowsAwayFromTheDefault() {
        let misc = "/Users/mike/dev/me/misc"
        XCTAssertFalse(ComposerChips.showsFolder(misc, defaultFolder: misc))
        XCTAssertFalse(ComposerChips.showsFolder(misc + "/", defaultFolder: misc))
        XCTAssertFalse(ComposerChips.showsFolder(misc, defaultFolder: misc + "//"))
        XCTAssertTrue(ComposerChips.showsFolder("/Users/mike/dev/photo-sync", defaultFolder: misc))
        XCTAssertTrue(ComposerChips.showsFolder("/Users/mike/dev/me", defaultFolder: misc))
        let home = NSHomeDirectory()
        XCTAssertFalse(ComposerChips.showsFolder("~/dev/me/misc", defaultFolder: home + "/dev/me/misc"))
        // Before the runner says what its default is, show the folder.
        XCTAssertTrue(ComposerChips.showsFolder(misc, defaultFolder: ""))
        XCTAssertFalse(ComposerChips.showsFolder("/", defaultFolder: "/"))
    }

    /// No model is the account's default; aliases and Claude ids read as
    /// words; anything unexpected stays as typed.
    func testModelChip() {
        XCTAssertEqual(ComposerChips.model(nil), "Default")
        XCTAssertEqual(ComposerChips.model(""), "Default")
        XCTAssertEqual(ComposerChips.model("opus"), "Opus")
        XCTAssertEqual(ComposerChips.model("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ComposerChips.model("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ComposerChips.model("claude-sonnet-4"), "Sonnet 4")
        XCTAssertEqual(ComposerChips.model("claude-3-5-sonnet-20241022"), "claude-3-5-sonnet-20241022")
        XCTAssertEqual(ComposerChips.model("opus[1m]"), "opus[1m]")
        XCTAssertEqual(ComposerChips.model("gpt-6"), "gpt-6")
    }

    /// Blank text alone can't be sent; an image on its own can.
    func testCanSend() {
        XCTAssertFalse(ComposerChips.canSend(text: "", imageCount: 0))
        XCTAssertFalse(ComposerChips.canSend(text: "  \n\t", imageCount: 0))
        XCTAssertTrue(ComposerChips.canSend(text: "hi", imageCount: 0))
        XCTAssertTrue(ComposerChips.canSend(text: " ", imageCount: 1))
    }

    /// Two lines at least, ten at most, whole points in between.
    func testBoxHeightClampsToTwoToTenLines() {
        let line: CGFloat = 17
        XCTAssertEqual(ComposerChips.boxHeight(textHeight: 0, lineHeight: line), 34)
        XCTAssertEqual(ComposerChips.boxHeight(textHeight: 17, lineHeight: line), 34)
        XCTAssertEqual(ComposerChips.boxHeight(textHeight: 50.2, lineHeight: line), 51)
        XCTAssertEqual(ComposerChips.boxHeight(textHeight: 400, lineHeight: line), 170)
    }
}
