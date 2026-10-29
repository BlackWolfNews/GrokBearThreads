import XCTest
@testable import ThreadbearCore

final class SidebarRowTests: XCTestCase {
    func look(_ status: ThreadStatus, needsYou: Bool = false) -> ThreadRowLook {
        ThreadRowLook(ThreadSummary(id: "t", title: "t", status: status, needsYou: needsYou))
    }

    /// Between turns with sub-agents or jobs still going, the row says so
    /// (and keeps saying so under the Running heading, since the words are
    /// what's running, not the heading's). An unread reply waits for its
    /// dot until the work's done: a dot by a spinner read as two states at
    /// once (Mike, 27 Oct). The bold title still says there's a reply.
    func testBackgroundWorkShowsOnTheRow() {
        let cubs = [BackgroundTask(kind: .agent, description: "a"), BackgroundTask(kind: .agent, description: "b"), BackgroundTask(kind: .agent, description: "c")]
        let thread = ThreadSummary(id: "t", title: "t", status: .idle, background: cubs)
        XCTAssertEqual(ThreadRowLook(thread), ThreadRowLook(status: .background, unread: false, emphasised: false))
        XCTAssertEqual(ThreadRowLook(thread, section: .running), ThreadRowLook(status: .background, unread: false, emphasised: false, labelled: true))
        var unread = thread
        unread.needsYou = true
        XCTAssertEqual(ThreadRowLook(unread), ThreadRowLook(status: .background, unread: false, emphasised: true))
        unread.background = []
        XCTAssertEqual(ThreadRowLook(unread), ThreadRowLook(status: .time, unread: true, emphasised: true))
        // A running turn is the working line, whatever's in the background.
        var running = thread
        running.status = .running
        XCTAssertEqual(ThreadRowLook(running).status, .working)
        var failed = thread
        failed.status = .error
        XCTAssertEqual(ThreadRowLook(failed).status, .failed)
        XCTAssertEqual(ThreadRowStatus.background.label, "In the background")
    }

    func testBackgroundWords() {
        let agent = { (d: String) in BackgroundTask(kind: .agent, description: d) }
        let shell = { (d: String) in BackgroundTask(kind: .shell, description: d) }
        XCTAssertEqual(BackgroundWork.short([agent("a"), agent("b"), agent("c")]), "3 sub-agents")
        XCTAssertEqual(BackgroundWork.short([agent("a")]), "1 sub-agent")
        XCTAssertEqual(BackgroundWork.short([shell("npm test")]), "1 job")
        XCTAssertEqual(BackgroundWork.short([shell("a"), shell("b")]), "2 jobs")
        XCTAssertEqual(BackgroundWork.short([agent("a"), shell("b")]), "2 jobs")
        XCTAssertEqual(BackgroundWork.short([BackgroundTask(kind: .monitor, description: "")]), "1 monitor")
        XCTAssertEqual(BackgroundWork.short([BackgroundTask(kind: .agent, description: "a", finished: true)]), "Finishing")
        XCTAssertEqual(BackgroundWork.short([agent("a"), BackgroundTask(kind: .agent, description: "b", finished: true)]), "1 sub-agent")

        XCTAssertEqual(BackgroundWork.line([agent("a"), agent("b"), agent("c")]), "3 sub-agents working in the background")
        XCTAssertEqual(BackgroundWork.line([shell("npm test")]), "1 job running in the background")
        XCTAssertEqual(BackgroundWork.line([agent("a"), agent("b"), shell("npm test")]), "2 sub-agents and 1 job running in the background")
        XCTAssertEqual(BackgroundWork.line([agent("a"), shell("b"), BackgroundTask(kind: .monitor, description: "c")]), "1 sub-agent, 1 job and 1 monitor running in the background")
        XCTAssertEqual(BackgroundWork.line([agent("a"), BackgroundTask(kind: .agent, description: "b", finished: true)]), "1 sub-agent working in the background, 1 just finished")
        XCTAssertEqual(BackgroundWork.line([BackgroundTask(kind: .agent, description: "b", finished: true)]), "1 sub-agent just finished, about to read its result")
        XCTAssertEqual(BackgroundWork.line([BackgroundTask(kind: .shell, description: "b", finished: true), BackgroundTask(kind: .agent, description: "c", finished: true)]), "2 jobs just finished, about to read their results")

        XCTAssertEqual(BackgroundWork.detail([agent("Rebuild page A"), BackgroundTask(kind: .shell, description: "", finished: true)]), "Rebuild page A\n1 job (finished)")
        XCTAssertEqual(BackgroundWork.lineWithDetail([agent("Rebuild page A"), agent("Rebuild page B")]), "2 sub-agents working in the background · Rebuild page A, Rebuild page B")
        XCTAssertEqual(BackgroundWork.lineWithDetail([BackgroundTask(kind: .other, description: "")]), "1 task running in the background")
        let long = String(repeating: "x", count: 70) + "\nsecond line"
        XCTAssertEqual(BackgroundWork.lineWithDetail([shell(long)]), "1 job running in the background · " + String(repeating: "x", count: 59) + "…")
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

    /// Under "Running" a working row doesn't say "Working" again; a row
    /// whose state differs from its section still says its word. Waiting
    /// rows in the inbox say "Needs you", since that's why they're on top.
    func testSectionWordsAreNotRepeated() {
        func look(_ status: ThreadStatus, needsYou: Bool = false, in section: InboxSection) -> ThreadRowLook {
            ThreadRowLook(ThreadSummary(id: "t", title: "t", status: status, needsYou: needsYou), section: section)
        }
        XCTAssertEqual(look(.running, in: .running), ThreadRowLook(status: .working, unread: false, emphasised: false, labelled: false))
        XCTAssertEqual(look(.starting, in: .running).labelled, false)
        XCTAssertEqual(look(.waiting, in: .inbox), ThreadRowLook(status: .needsYou, unread: false, emphasised: true, labelled: true))
        XCTAssertEqual(look(.idle, needsYou: true, in: .inbox), ThreadRowLook(status: .time, unread: true, emphasised: true))
        XCTAssertTrue(look(.error, needsYou: true, in: .inbox).labelled)
        XCTAssertTrue(look(.stopped, in: .inbox).labelled)
        // Outside the inbox (snoozed, archived) there's no section to lean on.
        XCTAssertTrue(ThreadRowLook(ThreadSummary(id: "t", title: "t", status: .waiting)).labelled)
    }

    func testSectionTitles() {
        XCTAssertEqual(InboxSection.allCases.map(\.title), ["Inbox", "Running", "Waiting", "Hibernating", "Archive"])
        let sections = ThreadSections(inbox: [ThreadSummary(id: "b", title: "b")], running: [ThreadSummary(id: "a", title: "a")])
        XCTAssertEqual(sections[.running].map(\.id), ["a"])
        XCTAssertEqual(sections[.inbox].map(\.id), ["b"])
        XCTAssertEqual(sections.all.map(\.id), ["b", "a"])
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

    func testProjectMark() {
        XCTAssertEqual(ProjectMark.letter("convex docs"), "C")
        XCTAssertEqual(ProjectMark.letter("  7 day plan"), "7")
        XCTAssertEqual(ProjectMark.letter("🐻 Threadbear"), "T")
        XCTAssertEqual(ProjectMark.letter("🐻"), "?")
        XCTAssertEqual(ProjectMark.letter(""), "?")
    }

    func testProjectMarkForNoneOneAndTwoProjects() {
        var thread = ThreadSummary(id: "t", title: "t", cwd: "/Users/mike/dev/me/misc")
        XCTAssertEqual(ProjectMark.shown(thread), [])
        XCTAssertEqual(ProjectMark.place(thread), "misc", "no project: the folder")
        XCTAssertEqual(ProjectMark.help(thread), "/Users/mike/dev/me/misc")
        thread.projects = [ThreadProject(id: "a", title: "Threadbear")]
        XCTAssertEqual(ProjectMark.place(thread), "Threadbear")
        thread.projects.append(ThreadProject(id: "b", title: ""))
        XCTAssertEqual(ProjectMark.shown(thread).map(\.id), ["a", "b"])
        XCTAssertEqual(ProjectMark.place(thread), "Threadbear, Untitled project")
        XCTAssertEqual(ProjectMark.help(thread), "Threadbear, Untitled project")
        // Under a project's heading the row names only the others, and its
        // folder when there are none.
        XCTAssertEqual(ProjectMark.place(thread, under: "a"), "Untitled project")
        XCTAssertEqual(ProjectMark.shown(thread, under: "b").map(\.id), ["a"])
        thread.projects.removeLast()
        XCTAssertEqual(ProjectMark.place(thread, under: "a"), "misc")
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
