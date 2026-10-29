import XCTest
import ThreadbearCore
@testable import Threadbear

/// Another runner's thread stays that runner's when its own summary is
/// stored over it: markSeen's reply, a rename's or an archive's never carry
/// the app's runnerId marker. Losing it sent the next calls to this Mac's
/// runner ("Thread not found") and dropped that runner's live events, which
/// is what Mike saw opening a thread on bruce on 30 Oct.
@MainActor
final class RemoteRunnerMarkTests: XCTestCase {
    func testAReplyStoredOverARemoteThreadKeepsItsRunner() {
        let app = AppModel()
        var remote = ThreadSummary(id: "t1", title: "Hello from Bruce", status: .idle)
        remote.runnerId = "r-bruce"
        app.threads["t1"] = remote
        app.threads["local"] = ThreadSummary(id: "local", title: "This Mac's", status: .idle)

        // As the runner sends it back: no runnerId.
        app.threads["t1"] = ThreadSummary(id: "t1", title: "Hello from Bruce", status: .running)
        XCTAssertEqual(app.threads["t1"]?.runnerId, "r-bruce")
        XCTAssertEqual(app.threads["t1"]?.status, .running, "the rest of the reply is kept")

        // This Mac's own threads never gain one.
        app.threads["local"] = ThreadSummary(id: "local", title: "Renamed", status: .idle)
        XCTAssertNil(app.threads["local"]?.runnerId)

        // Gone is gone.
        app.threads["t1"] = nil
        XCTAssertNil(app.threads["t1"])
    }
}
