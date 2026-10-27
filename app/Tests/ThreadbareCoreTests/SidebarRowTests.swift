import XCTest
@testable import ThreadbareCore

final class SidebarRowTests: XCTestCase {
    func look(_ status: ThreadStatus, needsYou: Bool = false) -> ThreadRowLook {
        ThreadRowLook(ThreadSummary(id: "t", title: "t", status: status, needsYou: needsYou))
    }

    func testStatusInWords() {
        XCTAssertEqual(look(.idle), ThreadRowLook(status: .time, unread: false, emphasised: false))
        XCTAssertEqual(look(.running), ThreadRowLook(status: .working, unread: false, emphasised: false))
        XCTAssertEqual(look(.starting).status, .working)
        XCTAssertEqual(look(.error).status, .failed)
        XCTAssertEqual(look(.stopped).status, .stopped)
        XCTAssertEqual(ThreadRowStatus.working.label, "Working")
        XCTAssertEqual(ThreadRowStatus.needsYou.label, "Needs you")
        XCTAssertNil(ThreadRowStatus.time.label)
    }

    /// Waiting on Mike says "Needs you" in words, so it gets no unread dot
    /// as well; a finished, unread thread gets the dot and the time.
    func testUnreadDotOnlyForFinishedThreads() {
        XCTAssertEqual(look(.waiting, needsYou: true), ThreadRowLook(status: .needsYou, unread: false, emphasised: true))
        XCTAssertEqual(look(.waiting), ThreadRowLook(status: .needsYou, unread: false, emphasised: true))
        XCTAssertEqual(look(.idle, needsYou: true), ThreadRowLook(status: .time, unread: true, emphasised: true))
        XCTAssertEqual(look(.error, needsYou: true), ThreadRowLook(status: .failed, unread: true, emphasised: true))
        XCTAssertFalse(look(.running, needsYou: true).unread)
    }

    /// Under "Needs you" and "Running" a row doesn't say its section's
    /// word again; a row whose state differs from its section still does.
    func testSectionWordsAreNotRepeated() {
        func look(_ status: ThreadStatus, needsYou: Bool = false, in section: InboxSection) -> ThreadRowLook {
            ThreadRowLook(ThreadSummary(id: "t", title: "t", status: status, needsYou: needsYou), section: section)
        }
        XCTAssertEqual(look(.waiting, in: .needsYou), ThreadRowLook(status: .needsYou, unread: false, emphasised: true, labelled: false))
        XCTAssertEqual(look(.running, in: .running), ThreadRowLook(status: .working, unread: false, emphasised: false, labelled: false))
        XCTAssertEqual(look(.starting, in: .running).labelled, false)
        // Finished and unread under Needs you: the dot and the time, as before.
        XCTAssertEqual(look(.idle, needsYou: true, in: .needsYou), ThreadRowLook(status: .time, unread: true, emphasised: true))
        // A failed thread under Needs you, or anything in the inbox, keeps its word.
        XCTAssertTrue(look(.error, needsYou: true, in: .needsYou).labelled)
        XCTAssertTrue(look(.stopped, in: .inbox).labelled)
        XCTAssertTrue(look(.waiting, in: .inbox).labelled)
        // Outside the inbox (snoozed, archived) there's no section to lean on.
        XCTAssertTrue(ThreadRowLook(ThreadSummary(id: "t", title: "t", status: .waiting)).labelled)
    }

    func testEmptyPreviewForAThreadWaitingOnMike() {
        XCTAssertEqual(ThreadRowLook.emptyPreview(ThreadSummary(id: "t", title: "t", status: .waiting)), "Waiting for your answer")
        XCTAssertEqual(ThreadRowLook.emptyPreview(ThreadSummary(id: "t", title: "t", status: .idle)), "No reply yet")
        XCTAssertEqual(ThreadRowLook.emptyPreview(ThreadSummary(id: "t", title: "t", status: .starting)), "No reply yet")
    }

    func testSectionTitles() {
        XCTAssertEqual(InboxSection.allCases.map(\.title), ["Needs you", "Running", "Inbox"])
        let sections = ThreadSections(needsYou: [ThreadSummary(id: "a", title: "a")], running: [], inbox: [ThreadSummary(id: "b", title: "b")])
        XCTAssertEqual(sections[.needsYou].map(\.id), ["a"])
        XCTAssertEqual(sections[.inbox].map(\.id), ["b"])
    }

    func testAccountShortNames() {
        let accounts = [
            Account(id: "claude-main", title: "mike@example.com"),
            Account(id: "claude-3", title: "mike+3@example.com"),
            Account(id: "work", title: "mike@work.example"),
            Account(id: "local", title: "Local"),
        ]
        XCTAssertEqual(AccountName.short("claude-3", accounts: accounts), "mike+3")
        // Two accounts share "mike", so both keep their whole address.
        XCTAssertEqual(AccountName.short("claude-main", accounts: accounts), "mike@example.com")
        XCTAssertEqual(AccountName.short("local", accounts: accounts), "Local")
        XCTAssertEqual(AccountName.short("gone", accounts: accounts), "gone")
    }

    func testAccountIsShownUnlessMain() {
        let accounts = [Account(id: "claude-main", title: "a@x"), Account(id: "claude-3", title: "b@x")]
        XCTAssertFalse(AccountName.isShown("claude-main", accounts: accounts, mainId: "claude-main"))
        XCTAssertTrue(AccountName.isShown("claude-3", accounts: accounts, mainId: "claude-main"))
        XCTAssertFalse(AccountName.isShown("", accounts: accounts, mainId: "claude-main"))
        // No main account: the first one is treated as main.
        let others = [Account(id: "work", title: "w@x"), Account(id: "home", title: "h@x")]
        XCTAssertFalse(AccountName.isShown("work", accounts: others, mainId: "claude-main"))
        XCTAssertTrue(AccountName.isShown("home", accounts: others, mainId: "claude-main"))
        // Before hello, with no accounts known, only the main id is unlabelled.
        XCTAssertTrue(AccountName.isShown("claude-3", accounts: [], mainId: "claude-main"))
    }

    func testFolderName() {
        XCTAssertEqual(FolderName.short("/Users/mike/dev/me/misc"), "misc")
        XCTAssertEqual(FolderName.short("~/dev/photo-sync/"), "photo-sync")
        XCTAssertEqual(FolderName.short("~"), "~")
        XCTAssertEqual(FolderName.short("/"), "/")
        XCTAssertEqual(FolderName.short(""), "")
    }

    func testKeyboardOrder() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(SidebarOrder.neighbour(of: "a", in: ids, step: 1), "b")
        XCTAssertEqual(SidebarOrder.neighbour(of: "c", in: ids, step: 1), "c", "stops at the end")
        XCTAssertEqual(SidebarOrder.neighbour(of: "a", in: ids, step: -1), "a", "stops at the start")
        XCTAssertEqual(SidebarOrder.neighbour(of: nil, in: ids, step: 1), "a")
        XCTAssertEqual(SidebarOrder.neighbour(of: "gone", in: ids, step: -1), "c")
        XCTAssertNil(SidebarOrder.neighbour(of: "a", in: [], step: 1))
    }
}

final class ComposerPlacementTests: XCTestCase {
    func testAtTheBottomUnderAThread() {
        XCTAssertEqual(ComposerPlacementMath.composerTop(paneHeight: 700, composerHeight: 110, centred: false), 590)
    }

    /// An empty new thread: the composer's middle about 40% down.
    func testAboutFortyPercentDownForANewThread() {
        let top = ComposerPlacementMath.composerTop(paneHeight: 700, composerHeight: 112, centred: true, headingHeight: 30, noteHeight: 16)
        XCTAssertEqual(top, 224)
        XCTAssertEqual((top + 56) / 700, 0.4, accuracy: 0.01)
    }

    /// Typing grows the composer downwards; its top stays put.
    func testGrowingComposerKeepsItsTop() {
        let empty = ComposerPlacementMath.composerTop(paneHeight: 700, composerHeight: 112, centred: true)
        let tall = ComposerPlacementMath.composerTop(paneHeight: 700, composerHeight: 260, centred: true)
        XCTAssertEqual(empty, tall)
    }

    func testShortWindowsKeepTheHeadingAndTheNoteOnScreen() {
        // The heading needs 30 + 40 above the composer.
        XCTAssertEqual(ComposerPlacementMath.composerTop(paneHeight: 300, composerHeight: 110, centred: true, headingHeight: 30, noteHeight: 16), 70)
        // Too short for everything: the composer and its note stay on screen.
        XCTAssertEqual(ComposerPlacementMath.composerTop(paneHeight: 180, composerHeight: 110, centred: true, headingHeight: 30, noteHeight: 16), 54)
        XCTAssertEqual(ComposerPlacementMath.composerTop(paneHeight: 80, composerHeight: 110, centred: true), 0)
    }
}

final class DockBadgeTests: XCTestCase {
    func testBadgeCountsThreadsThatNeedYouAndNothingElse() {
        let now = Date()
        let waiting = ThreadSummary(id: "a", title: "a", status: .waiting)
        let unread = ThreadSummary(id: "b", title: "b", needsYou: true)
        let running = ThreadSummary(id: "c", title: "c", status: .running)
        let snoozed = ThreadSummary(id: "d", title: "d", needsYou: true, snoozedUntil: now.addingTimeInterval(3600))
        let archived = ThreadSummary(id: "e", title: "e", needsYou: true, archivedAt: now)
        XCTAssertEqual(DockBadge.label(for: [waiting, unread, running, snoozed, archived], now: now), "2")
        XCTAssertNil(DockBadge.label(for: [running], now: now))
        XCTAssertNil(DockBadge.label(needsYou: 0))
    }
}
