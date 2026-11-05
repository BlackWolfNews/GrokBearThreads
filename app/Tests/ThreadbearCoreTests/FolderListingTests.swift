import Foundation
import XCTest
@testable import ThreadbearCore

final class FolderListingTests: XCTestCase {
    private func entry(_ name: String, folder: Bool = false, size: Int? = nil, at: TimeInterval? = nil) -> FolderEntry {
        FolderEntry(name: name, path: "/f/" + name, isFolder: folder, size: size, modifiedAt: at.map { Date(timeIntervalSince1970: $0) })
    }

    private func names(_ entries: [FolderEntry]) -> [String] { entries.map(\.name) }

    func testNameSortKeepsFoldersFirstAndNumbersInOrder() {
        let rows = [entry("clip 10.mp4"), entry("zed", folder: true), entry("clip 2.mp4"), entry("alpha", folder: true)]
        XCTAssertEqual(names(FolderSort().apply(rows)), ["alpha", "zed", "clip 2.mp4", "clip 10.mp4"])
        XCTAssertEqual(names(FolderSort(key: .name, ascending: false).apply(rows)), ["zed", "alpha", "clip 10.mp4", "clip 2.mp4"])
    }

    /// Newest first is how Mike finds what an agent just made.
    func testDateSortPutsTheUndatedLastBothWays() {
        let rows = [entry("old", at: 1), entry("none"), entry("new", at: 9), entry("mid", at: 5)]
        XCTAssertEqual(names(FolderSort(key: .modified, ascending: false).apply(rows)), ["new", "mid", "old", "none"])
        XCTAssertEqual(names(FolderSort(key: .modified, ascending: true).apply(rows)), ["old", "mid", "new", "none"])
    }

    func testTiesGoByNameWhicheverWayTheColumnRuns() {
        let rows = [entry("b", size: 5), entry("a", size: 5), entry("c", size: 9)]
        XCTAssertEqual(names(FolderSort(key: .size, ascending: false).apply(rows)), ["c", "a", "b"])
        XCTAssertEqual(names(FolderSort(key: .size, ascending: true).apply(rows)), ["a", "b", "c"])
    }

    func testCrumbsStartAtHomeWhenUnderIt() {
        XCTAssertEqual(FolderListing.crumbs(to: "/Users/me/dev/clips/", home: "/Users/me"), [
            .init(name: "me", path: "/Users/me"),
            .init(name: "dev", path: "/Users/me/dev"),
            .init(name: "clips", path: "/Users/me/dev/clips"),
        ])
        XCTAssertEqual(FolderListing.crumbs(to: "/Users/me", home: "/Users/me"), [.init(name: "me", path: "/Users/me")])
    }

    func testCrumbsStartAtTheDiskOutsideHome() {
        // A sibling that only shares the prefix isn't under home.
        XCTAssertEqual(FolderListing.crumbs(to: "/Users/merle/x", home: "/Users/me"), [
            .init(name: "/", path: "/"),
            .init(name: "Users", path: "/Users"),
            .init(name: "merle", path: "/Users/merle"),
            .init(name: "x", path: "/Users/merle/x"),
        ])
        XCTAssertEqual(FolderListing.crumbs(to: "/", home: "/Users/me"), [.init(name: "/", path: "/")])
    }

    func testParentStopsAtTheTop() {
        XCTAssertEqual(FolderListing.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(FolderListing.parent(of: "/a"), "/")
        XCTAssertNil(FolderListing.parent(of: "/"))
    }

    func testReadsAFolderFollowingLinksAndKeepingTheirPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("exports"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.md"))
        try Data("X".utf8).write(to: root.appendingPathComponent(".env"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("to-exports"), withDestinationURL: root.appendingPathComponent("exports"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("never-there"))
        defer { try? fm.removeItem(at: root) }

        let listed = try FolderListing.read(root.path)
        let rows = Dictionary(uniqueKeysWithValues: listed.entries.map { ($0.name, $0) })
        XCTAssertEqual(rows["notes.md"]?.size, 5)
        XCTAssertEqual(rows["notes.md"]?.isFolder, false)
        XCTAssertNotNil(rows["notes.md"]?.modifiedAt)
        XCTAssertEqual(rows["exports"]?.isFolder, true)
        XCTAssertNil(rows["exports"]?.size)
        XCTAssertEqual(rows[".env"]?.hidden, true)
        XCTAssertEqual(rows["to-exports"]?.isFolder, true, "a link to a folder opens as one")
        XCTAssertEqual(rows["to-exports"]?.path, root.path + "/to-exports", "and stays under the link")
        XCTAssertEqual(rows["Tool.app"]?.isFolder, false, "a package opens in its app")
        XCTAssertEqual(rows["Tool.app"]?.isPackage, true)
        XCTAssertEqual(rows["broken"]?.isFolder, false, "a broken link is still listed")

        XCTAssertTrue(FolderListing.isBrowsable(root.path))
        XCTAssertTrue(FolderListing.isBrowsable(root.path + "/to-exports"))
        XCTAssertFalse(FolderListing.isBrowsable(root.path + "/notes.md"))
        XCTAssertFalse(FolderListing.isBrowsable(root.path + "/Tool.app"))
        XCTAssertFalse(FolderListing.isBrowsable(root.path + "/never-there"))
    }

    /// The shape runner/src/files.ts sends.
    func testDecodesARunnersList() throws {
        let json = #"""
        {"path":"/Users/bruce/clips","truncated":true,"extra":1,"entries":[
          {"name":"a.mp4","isFolder":false,"hidden":false,"size":1024,"modifiedAt":"2026-11-05T01:02:03.456Z"},
          {"name":"sub","isFolder":true,"hidden":false,"modifiedAt":"2026-11-05T01:02:03.000Z"},
          {"name":"broken","isFolder":false,"hidden":false},
          {"name":".env"},
          {"isFolder":true}
        ]}
        """#
        let contents = try JSONDecoder().decode(FolderContents.self, from: Data(json.utf8))
        XCTAssertEqual(contents.path, "/Users/bruce/clips")
        XCTAssertTrue(contents.truncated)
        XCTAssertEqual(contents.entries.map(\.name), ["a.mp4", "sub", "broken", ".env"], "one with no name is dropped")
        XCTAssertEqual(contents.entries[0].path, "/Users/bruce/clips/a.mp4")
        XCTAssertEqual(contents.entries[0].size, 1024)
        XCTAssertEqual(contents.entries[0].modifiedAt?.timeIntervalSince1970 ?? 0, 1_793_840_523.456, accuracy: 0.01)
        XCTAssertTrue(contents.entries[1].isFolder)
        XCTAssertNil(contents.entries[2].modifiedAt)
        XCTAssertTrue(contents.entries[3].hidden, "a dotfile is hidden even if it doesn't say")
    }
}
