import Foundation
import XCTest
@testable import Threadbare

/// The installed app's self-update: what to build, and the swap of a
/// staged bundle into the installed one's place.
final class AppUpdateTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func info(_ short: String, tree: String) -> BuildInfo {
        BuildInfo(commit: short + "000", short: short, appTree: tree, builtAt: "2026-10-27T00:00:00Z", checkout: "/tmp/x", configuration: "release")
    }

    /// A bundle folder with a build.json and a marker file naming it.
    private func bundle(_ name: String, _ build: BuildInfo) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try JSONEncoder().encode(build).write(to: url.appendingPathComponent("Contents/Resources/build.json"))
        try Data(build.short.utf8).write(to: url.appendingPathComponent("Contents/marker"))
        return url
    }

    private func marker(_ url: URL) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testDecidesWhetherToBuild() {
        let running = info("aaa", tree: "t1")
        XCTAssertEqual(AppUpdate.decide(mainTree: "t1", running: running, staged: nil, building: nil, failed: nil), .nothing)
        XCTAssertEqual(AppUpdate.decide(mainTree: "t2", running: running, staged: nil, building: nil, failed: nil), .build(appTree: "t2"))
        // Already staged, being built or known to fail: leave it.
        XCTAssertEqual(AppUpdate.decide(mainTree: "t2", running: running, staged: info("bbb", tree: "t2"), building: nil, failed: nil), .nothing)
        XCTAssertEqual(AppUpdate.decide(mainTree: "t2", running: running, staged: nil, building: "t2", failed: nil), .nothing)
        XCTAssertEqual(AppUpdate.decide(mainTree: "t2", running: running, staged: nil, building: nil, failed: "t2"), .nothing)
        // Main moved on past a failed or staged tree: build the new one.
        XCTAssertEqual(AppUpdate.decide(mainTree: "t3", running: running, staged: info("bbb", tree: "t2"), building: nil, failed: "t2"), .build(appTree: "t3"))
        // Main is back to what's running while something else is staged.
        XCTAssertEqual(AppUpdate.decide(mainTree: "t1", running: running, staged: info("bbb", tree: "t2"), building: nil, failed: nil), .dropStaged)
    }

    func testRestartsByItselfOnlyWhenNothingWouldBeInterrupted() {
        let idle = AppUpdater.autoRestartIdleTime
        // Another app in front: straight away.
        XCTAssertTrue(AppUpdate.shouldAutoRestart(staged: true, loaded: true, working: false, hasDrafts: false, active: false, idleFor: 0))
        // Threadbare in front: only after a while with no input.
        XCTAssertFalse(AppUpdate.shouldAutoRestart(staged: true, loaded: true, working: false, hasDrafts: false, active: true, idleFor: idle - 1))
        XCTAssertTrue(AppUpdate.shouldAutoRestart(staged: true, loaded: true, working: false, hasDrafts: false, active: true, idleFor: idle))
        // A running thread, unsent text, no build or no thread list: never.
        XCTAssertFalse(AppUpdate.shouldAutoRestart(staged: true, loaded: true, working: true, hasDrafts: false, active: false, idleFor: idle))
        XCTAssertFalse(AppUpdate.shouldAutoRestart(staged: true, loaded: true, working: false, hasDrafts: true, active: false, idleFor: idle))
        XCTAssertFalse(AppUpdate.shouldAutoRestart(staged: false, loaded: true, working: false, hasDrafts: false, active: false, idleFor: idle))
        XCTAssertFalse(AppUpdate.shouldAutoRestart(staged: true, loaded: false, working: false, hasDrafts: false, active: false, idleFor: idle))
    }

    func testSwapPutsTheStagedBundleInPlaceAndKeepsTheOld() throws {
        let install = try bundle("Threadbare.app", info("aaa", tree: "t1"))
        let next = try bundle(".Threadbare.app.next", info("bbb", tree: "t2"))
        let old = root.appendingPathComponent(".Threadbare.app.old")
        try AppUpdate.swap(install: install, next: next, old: old)
        XCTAssertEqual(marker(install), "bbb")
        XCTAssertEqual(marker(old), "aaa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.path))
    }

    func testApplyStagedSwapsOnlyADifferentBuild() throws {
        let install = try bundle("Threadbare.app", info("aaa", tree: "t1"))
        let old = root.appendingPathComponent(".Threadbare.app.old")
        // Same app/ tree as what's running: dropped, nothing swapped.
        var next = try bundle(".Threadbare.app.next", info("aab", tree: "t1"))
        XCTAssertNil(AppUpdate.applyStaged(install: install, next: next, old: old, running: info("aaa", tree: "t1")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.path))
        XCTAssertEqual(marker(install), "aaa")
        // A leftover from an earlier swap is cleared, and a new build goes in.
        _ = try bundle(".Threadbare.app.old", info("zzz", tree: "t0"))
        next = try bundle(".Threadbare.app.next", info("bbb", tree: "t2"))
        let applied = AppUpdate.applyStaged(install: install, next: next, old: old, running: info("aaa", tree: "t1"))
        XCTAssertEqual(applied?.short, "bbb")
        XCTAssertEqual(marker(install), "bbb")
        XCTAssertEqual(marker(old), "aaa")
        // Nothing staged: nothing happens.
        XCTAssertNil(AppUpdate.applyStaged(install: install, next: next, old: old, running: info("bbb", tree: "t2")))
        XCTAssertEqual(marker(install), "bbb")
    }

    func testAStagedFolderWithoutBuildInfoIsDropped() throws {
        let install = try bundle("Threadbare.app", info("aaa", tree: "t1"))
        let next = root.appendingPathComponent(".Threadbare.app.next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        XCTAssertNil(AppUpdate.applyStaged(install: install, next: next, old: root.appendingPathComponent("old"), running: info("aaa", tree: "t1")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.path))
        XCTAssertEqual(marker(install), "aaa")
    }

    func testBuildInfoReadsWhatBuildAppWrites() throws {
        let url = try bundle("Threadbare.app", info("abc1234", tree: "t9"))
        XCTAssertEqual(BuildInfo.read(bundle: url)?.short, "abc1234")
        XCTAssertNil(BuildInfo.read(bundle: root.appendingPathComponent("missing.app")))
    }
}
