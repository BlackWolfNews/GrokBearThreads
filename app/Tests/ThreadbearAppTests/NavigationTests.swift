import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

@MainActor
final class NavigationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func app() -> AppModel {
        let app = AppModel()
        app.notificationsEnabled = false
        for id in ["a", "b", "c"] { app.threads[id] = ThreadSummary(id: id, title: id) }
        app.projects = [Project(id: "p_a", title: "Threadbear")]
        app.projectsSupported = true
        return app
    }

    /// Lets the main queue record the step a click made.
    private func settle() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    func testBackAndForwardThroughThreadsAndViews() async {
        let app = app()
        app.select("a")
        await settle()
        app.select("b")
        await settle()
        app.showProjects()
        await settle()
        app.openProjectPage("p_a")
        await settle()

        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .projects, threadId: "b", projectsHome: true))
        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .inbox, threadId: "b"))
        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .inbox, threadId: "a"))
        XCTAssertFalse(app.canGoBack)
        await settle()
        XCTAssertEqual(app.history.entries.count, 4, "going back records nothing new")

        app.goForward()
        app.goForward()
        app.goForward()
        XCTAssertEqual(app.place, NavigationPlace(mode: .projects, threadId: "b", projectId: "p_a"))
        XCTAssertFalse(app.canGoForward)
    }

    /// Projects opens the page of cards; a card, a thread, or another view
    /// closes it, and Back comes back to it.
    func testProjectsOpensItsPageOfCards() async {
        let app = app()
        app.select("a")
        await settle()
        app.showProjects()
        await settle()
        XCTAssertTrue(app.showsProjectsHome)
        XCTAssertEqual(app.selection, "a", "the thread stays selected for when Mike goes back to it")
        app.openProjectPage("p_a")
        XCTAssertFalse(app.showsProjectsHome)
        await settle()
        app.goBack()
        XCTAssertTrue(app.showsProjectsHome)
        XCTAssertNil(app.openProjectId)
        app.select("b")
        XCTAssertFalse(app.showsProjectsHome)
        app.showProjects()
        app.sidebarMode = .inbox
        XCTAssertFalse(app.showsProjectsHome, "leaving the Projects view closes it")
    }

    /// Librarian opens its page in the detail area; a thread, a project
    /// or another view closes it, and Back comes back to it.
    func testLibrarianOpensItsPage() async {
        let app = app()
        app.select("a")
        await settle()
        app.showLibrarian()
        await settle()
        XCTAssertTrue(app.showsLibrarianHome)
        XCTAssertTrue(app.showsHomePage)
        XCTAssertEqual(app.selection, "a", "the thread stays selected for when Mike goes back to it")
        app.select("b")
        XCTAssertFalse(app.showsLibrarianHome)
        await settle()
        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .librarian, threadId: "a", librarianHome: true))
        app.openProjectPage("p_a")
        XCTAssertFalse(app.showsLibrarianHome)
        app.showLibrarian()
        app.showProjects()
        XCTAssertFalse(app.showsLibrarianHome, "leaving the Librarian view closes it")
        XCTAssertTrue(app.showsProjectsHome)
    }

    /// Scheduled opens its page too, and closes the same ways.
    func testScheduledOpensItsPage() async {
        let app = app()
        app.schedulesSupported = true
        app.select("a")
        await settle()
        app.showSchedules()
        await settle()
        XCTAssertTrue(app.showsScheduledHome)
        XCTAssertTrue(app.showsHomePage)
        XCTAssertEqual(app.selection, "a")
        app.select("b")
        XCTAssertFalse(app.showsScheduledHome)
        await settle()
        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .scheduled, threadId: "a", scheduledHome: true))
        app.showLibrarian()
        XCTAssertFalse(app.showsScheduledHome, "leaving the Scheduled view closes it")
        XCTAssertTrue(app.showsLibrarianHome)
    }

    /// Hibernating and Archive are inbox sections now: showing one is the
    /// inbox with that section unfolded, and opening a put-away thread
    /// unfolds its section.
    func testPutAwaySectionsUnfoldInTheInbox() {
        let app = app()
        app.threads["z"] = ThreadSummary(id: "z", title: "z", snoozedUntil: Date().addingTimeInterval(3600))
        app.threads["x"] = ThreadSummary(id: "x", title: "x", archivedAt: Date())
        app.collapsedSections = [.hibernating, .archived]
        app.showSchedules()
        app.showArchive()
        XCTAssertEqual(app.sidebarMode, .inbox)
        XCTAssertEqual(app.collapsedSections, [.hibernating])
        app.collapsedSections = [.hibernating, .archived]
        app.openThread("z")
        XCTAssertEqual(app.collapsedSections, [.archived])
        XCTAssertEqual(app.selection, "z")
        app.openThread("x")
        XCTAssertEqual(app.collapsedSections, [])
    }

    /// The two put-away sections start folded, once, then stay how Mike
    /// leaves them.
    func testPutAwaySectionsStartFolded() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NavigationTests.\(UUID().uuidString)"))
        defaults.set(["running"], forKey: AppModel.collapsedSectionsKey)
        XCTAssertEqual(AppModel.storedCollapsedSections(defaults), [.running, .hibernating, .archived])
        defaults.set(["running"], forKey: AppModel.collapsedSectionsKey)
        XCTAssertEqual(AppModel.storedCollapsedSections(defaults), [.running], "opened ones stay open")
    }

    /// The Archive section shows the most recent few, more on asking, every
    /// match while searching, and always the open thread.
    func testArchiveRowsAreCutShort() {
        let archived = (0..<30).map { ThreadSummary(id: "t\($0)", title: "t\($0)") }
        var shown = ArchiveRows.shown(archived, limit: 20, searching: false, selection: nil)
        XCTAssertEqual(shown.rows.count, 20)
        XCTAssertEqual(shown.more, 10)
        shown = ArchiveRows.shown(archived, limit: 20, searching: false, selection: "t25")
        XCTAssertEqual(shown.rows.last?.id, "t25")
        XCTAssertEqual(shown.more, 4)
        shown = ArchiveRows.shown(archived, limit: 20, searching: true, selection: nil)
        XCTAssertEqual(shown.rows.count, 30)
        XCTAssertEqual(shown.more, 0)
        XCTAssertEqual(ArchiveRows.shown(archived, limit: 70, searching: false, selection: nil).more, 0)
    }

    /// The Scheduled page's numbers and what's next.
    func testScheduledStats() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = """
        [{"id":"a","title":"Soon","text":"x","at":"\(ISO8601.format(now.addingTimeInterval(600)))","whenText":"once","paused":false,"createdAt":"\(ISO8601.format(now))","updatedAt":"\(ISO8601.format(now))","nextRunAt":"\(ISO8601.format(now.addingTimeInterval(600)))","runs":0},
         {"id":"b","title":"Daily","text":"x","cron":"0 9 * * *","whenText":"Every day at 9:00","paused":false,"createdBy":"t1","createdAt":"\(ISO8601.format(now))","updatedAt":"\(ISO8601.format(now))","nextRunAt":"\(ISO8601.format(now.addingTimeInterval(3 * 86_400)))","runs":4},
         {"id":"c","title":"Off","text":"x","cron":"0 9 * * *","whenText":"Every day at 9:00","paused":true,"createdAt":"\(ISO8601.format(now))","updatedAt":"\(ISO8601.format(now))","runs":2}]
        """
        let schedules = try JSONDecoder().decode([Schedule].self, from: Data(json.utf8))
        XCTAssertEqual(ScheduledStats.next(schedules)?.id, "a")
        XCTAssertEqual(ScheduledStats.when(schedules[0], now: now), "in 10 min")
        let tiles = Dictionary(uniqueKeysWithValues: ScheduledStats.tiles(schedules, now: now).map { ($0.label, $0.value) })
        XCTAssertEqual(tiles["On"], "2")
        XCTAssertEqual(tiles["Due in a day"], "1")
        XCTAssertEqual(tiles["Repeating"], "1")
        XCTAssertEqual(tiles["Set by a thread"], "1")
        XCTAssertEqual(tiles["Paused"], "1")
        XCTAssertEqual(tiles["Runs so far"], "6")
        XCTAssertNil(ScheduledStats.next([schedules[2]]))
    }

    /// Picking a thread changes the selection and closes the project page
    /// in turn; that's one step, not two.
    func testOneClickIsOneStep() async {
        let app = app()
        app.select("a")
        await settle()
        app.openProjectPage("p_a")
        await settle()
        app.select("b")
        await settle()
        XCTAssertEqual(app.history.entries.map(\.threadId), ["a", "a", "b"])
        app.goBack()
        XCTAssertEqual(app.place, NavigationPlace(mode: .inbox, threadId: "a", projectId: "p_a"))
    }

    /// Back straight after a click, before the main queue has run, still
    /// goes to where it was before the click.
    func testBackBeforeTheStepIsRecorded() async {
        let app = app()
        app.select("a")
        await settle()
        app.select("b")
        app.goBack()
        XCTAssertEqual(app.selection, "a")
        XCTAssertTrue(app.canGoForward)
    }

    func testDeletedThreadsAreSkipped() async {
        let app = app()
        for id in ["a", "b", "c"] {
            app.select(id)
            await settle()
        }
        app.threads["b"] = nil
        app.goBack()
        XCTAssertEqual(app.selection, "a")
    }
}
