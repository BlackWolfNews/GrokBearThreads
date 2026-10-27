import XCTest
@testable import ThreadbareCore

/// The rail's updates icon and popover (UpdatesText), and the protocol bits
/// they read: hello's `updates`, `runner.updates` and `onOldRunner`.
final class UpdatesTextTests: XCTestCase {
    typealias Side = UpdatesText.AppSide

    func testShownOnlyWhileSomethingIsOnItsWayOrWentWrong() {
        let idle = RunnerUpdates(state: "idle")
        XCTAssertFalse(UpdatesText.shown(app: Side(running: "abc1234"), runner: idle))
        XCTAssertFalse(UpdatesText.shown(app: Side(), runner: nil), "an older runner says nothing")
        XCTAssertFalse(UpdatesText.shown(app: Side(), runner: RunnerUpdates(state: "checking")))
        XCTAssertTrue(UpdatesText.shown(app: Side(staged: "def5678"), runner: idle))
        XCTAssertTrue(UpdatesText.shown(app: Side(building: true), runner: idle))
        XCTAssertTrue(UpdatesText.shown(app: Side(), runner: RunnerUpdates(state: "building")))
        XCTAssertTrue(UpdatesText.shown(app: Side(), runner: RunnerUpdates(oldRunners: [.init(version: "old", threads: ["t1"])])))
        XCTAssertTrue(UpdatesText.shown(app: Side(), runner: RunnerUpdates(launcherChanged: true)))
        XCTAssertTrue(UpdatesText.shown(app: Side(), runner: RunnerUpdates(state: "failed", reason: "tests failed")))
    }

    func testOnlyALaunchMjsNeedsMike() {
        XCTAssertFalse(UpdatesText.needsYou(app: Side(staged: "def5678"), runner: RunnerUpdates(state: "building")))
        XCTAssertFalse(UpdatesText.needsYou(app: Side(), runner: RunnerUpdates(oldRunners: [.init(version: "old", threads: ["t1"])])))
        // A failed build tries again once main is fixed, so it's not his to do.
        XCTAssertFalse(UpdatesText.needsYou(app: Side(failed: true), runner: nil))
        XCTAssertFalse(UpdatesText.needsYou(app: Side(staged: "def5678"), runner: RunnerUpdates(state: "failed")))
        XCTAssertTrue(UpdatesText.needsYou(app: Side(), runner: RunnerUpdates(launcherChanged: true)))
    }

    func testTooltipNamesWhichSide() {
        XCTAssertEqual(UpdatesText.tooltip(app: Side(staged: "a"), runner: RunnerUpdates(state: "building")), "Updates for the app and the runner")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(staged: "a"), runner: RunnerUpdates()), "An app update")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(), runner: RunnerUpdates(state: "waiting")), "A runner update")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(), runner: RunnerUpdates(state: "failed")), "The runner's update failed")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(failed: true), runner: nil), "The app's update failed")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(failed: true), runner: RunnerUpdates(state: "failed")), "The app's and the runner's updates failed")
        XCTAssertEqual(UpdatesText.tooltip(app: Side(staged: "a"), runner: RunnerUpdates(state: "failed")), "Updates for the app and the runner")
    }

    func testLines() {
        XCTAssertEqual(UpdatesText.appLine(Side(running: "abc1234", staged: "def5678")),
                       "The app's next version (def5678) is ready. It switches in when you're not using the app, or now.")
        XCTAssertEqual(UpdatesText.appLine(Side(running: "abc1234")), "The app is up to date (abc1234).")
        XCTAssertEqual(UpdatesText.runnerLines(RunnerUpdates(state: "building", commit: "c131089", subject: "Handovers")),
                       ["Building the runner from main at c131089: Handovers."])
        XCTAssertEqual(UpdatesText.runnerLines(RunnerUpdates(state: "idle", oldRunners: [.init(version: "old", threads: ["t1", "t2"])], launcherChanged: true)), [
            "2 threads are finishing their turns on the previous version. Each moves to the new one when its turn ends.",
            "launch.mjs has changed on main. It only updates when you run this, once nothing is busy:",
        ])
        XCTAssertEqual(UpdatesText.runnerLines(RunnerUpdates(state: "idle")), ["The runner is up to date."])
        XCTAssertEqual(UpdatesText.installCommand(checkout: NSHomeDirectory() + "/dev/me/threadbare"), "~/dev/me/threadbare/runner/scripts/install-runner.sh")
        // Plain words: no em dashes.
        for line in UpdatesText.runnerLines(RunnerUpdates(state: "failed", commit: "a", reason: "x", oldRunners: [.init(version: "o", threads: ["t"])], launcherChanged: true)) {
            XCTAssertFalse(line.contains("\u{2014}"), line)
        }
    }

    func testHelloUpdatesAndOnOldRunnerDecode() throws {
        let hello = try JSONDecoder().decode(HelloResult.self, from: Data("""
        {"runnerVersion":"0.1.0+r","protocol":1,"accounts":[],"defaults":{"cwd":"/tmp","accountId":"claude-3"},
         "updates":{"state":"waiting","commit":"c131089","oldRunners":[{"version":"0.1.0+old","threads":["t1"]},{"broken":1}],"launcherChanged":true,"future":2}}
        """.utf8))
        XCTAssertEqual(hello.updates?.state, "waiting")
        XCTAssertEqual(hello.updates?.oldRunners.map(\.threads), [["t1"], []])
        XCTAssertEqual(hello.updates?.launcherChanged, true)
        XCTAssertEqual(hello.updates?.isPending, true)
        let older = try JSONDecoder().decode(HelloResult.self, from: Data(#"{"runnerVersion":"x","accounts":[],"defaults":{"cwd":"/","accountId":"a"}}"#.utf8))
        XCTAssertNil(older.updates)
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"t1","title":"x","onOldRunner":true}"#.utf8))
        XCTAssertTrue(thread.onOldRunner)
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertTrue(again.onOldRunner)
    }

    func testRunnerUpdatesNotification() async throws {
        let transport = FakeTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        transport.push(E.json(["jsonrpc": "2.0", "method": "runner.updates", "params": ["updates": ["state": "building", "commit": "abc1234"]]]))
        var iterator = client.notifications.makeAsyncIterator()
        guard case .runnerUpdates(let updates)? = await iterator.next() else { return XCTFail("no runner.updates") }
        XCTAssertEqual(updates.state, "building")
        XCTAssertEqual(updates.commit, "abc1234")
        XCTAssertEqual(updates.oldRunners, [])
    }
}
