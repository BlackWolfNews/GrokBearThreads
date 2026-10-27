import AppKit
import XCTest
@testable import Threadbare
@testable import ThreadbareCore

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
