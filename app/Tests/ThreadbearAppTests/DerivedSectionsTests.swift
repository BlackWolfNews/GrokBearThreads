import Observation
import XCTest
import ThreadbearCore
@testable import Threadbear

/// `sections` and `projectSections` are built once per change and kept, not
/// built again for every view that reads them. They must still follow every
/// change, and still tell the views reading them to redraw.
@MainActor
final class DerivedSectionsTests: XCTestCase {
    func testSectionsFollowEveryChange() {
        let app = AppModel()
        app.threads["a"] = ThreadSummary(id: "a", title: "One", status: .idle)
        XCTAssertEqual(app.sections.inbox.map(\.id), ["a"])
        app.threads["b"] = ThreadSummary(id: "b", title: "Two", status: .running)
        XCTAssertEqual(app.sections.running.map(\.id), ["b"])
        app.threads["a"]?.status = .running
        XCTAssertEqual(Set(app.sections.running.map(\.id)), ["a", "b"])
        XCTAssertTrue(app.sections.inbox.isEmpty)
    }

    func testProjectSectionsFollowProjectsAndThreads() {
        let app = AppModel()
        app.projects = [Project(id: "p", title: "Poddle")]
        XCTAssertEqual(app.projectSections.sections.map(\.project.title), ["Poddle"])
        app.threads["a"] = ThreadSummary(id: "a", title: "One", projects: [ThreadProject(id: "p", title: "Poddle")])
        XCTAssertEqual(app.projectSections.sections.first?.threads.map(\.id), ["a"])
        app.projects = [Project(id: "p", title: "Poddle 2")]
        XCTAssertEqual(app.projectSections.sections.map(\.project.title), ["Poddle 2"])
    }

    func testAReaderIsToldOfAThreadChangeEvenWhenTheMemoServedIt() {
        let app = AppModel()
        app.threads["a"] = ThreadSummary(id: "a", title: "One", status: .idle)
        _ = app.sections // fills the memo, so the read below hits it
        var told = false
        withObservationTracking { _ = app.sections } onChange: { told = true }
        app.threads["a"]?.preview = "Working"
        XCTAssertTrue(told)
        told = false
        withObservationTracking { _ = app.projectSections } onChange: { told = true }
        app.threads["a"]?.preview = "Still working"
        XCTAssertTrue(told)
    }
}
