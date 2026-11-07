import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// New Thread on a project's page: the new-thread box in the project's
/// first folder, the thread joining the project as it's made.
@MainActor
final class ProjectNewThreadTests: XCTestCase {
    func testNewThreadInAProjectStartsInItsFolder() {
        let app = AppModel()
        let project = Project(id: "p_walk", title: "Walkies", folders: ["/tmp/walkies", "/tmp/walkies-backend"])
        app.newThread(in: project)
        XCTAssertNil(app.selection)
        XCTAssertEqual(app.newThreadProjectId, "p_walk")
        XCTAssertEqual(app.newThreadCwd, "/tmp/walkies")
        XCTAssertNil(app.openProjectId, "the project page gives way to the new thread")
    }

    func testAPlainNewThreadIsntInAProject() {
        let app = AppModel()
        app.newThread(in: Project(id: "p_walk", title: "Walkies", folders: []))
        XCTAssertEqual(app.newThreadProjectId, "p_walk")
        XCTAssertNil(app.newThreadCwd, "no folder: the default one")
        app.newThread()
        XCTAssertNil(app.newThreadProjectId)
    }

    func testTheRequestCarriesTheProject() {
        var request = NewThreadRequest(text: "hi", cwd: "/tmp/walkies")
        XCTAssertEqual(request.projectIds, [])
        request.projectIds = ["p_walk"]
        XCTAssertEqual(request.projectIds, ["p_walk"])
    }
}
