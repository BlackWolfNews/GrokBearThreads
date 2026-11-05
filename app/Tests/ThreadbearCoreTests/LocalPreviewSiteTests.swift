import Foundation
import XCTest
@testable import ThreadbearCore

/// Daybreak finding 6: a local HTML preview reads itself and the assets it
/// names, never the other files beside it.
final class LocalPreviewSiteTests: XCTestCase {
    private var dir: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPreviewSiteTests-\(UUID().uuidString)")
        dir = base.appendingPathComponent("site")
        outside = base.appendingPathComponent("elsewhere")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("index.html", """
        <link rel="stylesheet" href="style.css?v=2">
        <img src="pic.png" srcset="pic.png 1x, assets/pic@2x.png 2x">
        <a href="about.html">About</a>
        <img src=../elsewhere/out.png><img src="secret.env"><img src="notes.json"><img src="logo.png"><img src="away.png">
        <img src="https://example.com/x.png"><img src="data:image/png;base64,AAAA">
        <script src="app.js"></script>
        """)
        try write("style.css", "body { background: url('assets/bg.png'); } @font-face { src: url(assets/font.woff2) }")
        try write("app.js", "const img = new Image(); img.src = `assets/late.png`;")
        for name in ["pic.png", "assets/pic@2x.png", "assets/bg.png", "assets/font.woff2", "assets/late.png", "about.html", "other.png", "notes.json"] {
            try write(name, "x")
        }
        try write(".env", "SECRET=1")
        try write("secret.env", "SECRET=2")
        try "far away".write(to: outside.appendingPathComponent("out.png"), atomically: true, encoding: .utf8)
        // An asset name linked to the dotfile beside it, and to a file elsewhere.
        try fm.createSymbolicLink(at: dir.appendingPathComponent("logo.png"), withDestinationURL: dir.appendingPathComponent(".env"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("away.png"), withDestinationURL: outside.appendingPathComponent("out.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func site() throws -> LocalPreviewSite {
        let site = try XCTUnwrap(LocalPreviewSite(file: dir.appendingPathComponent("index.html")))
        XCTAssertEqual(site.serve("/index.html")?.mimeType, "text/html")
        return site
    }

    /// The finding's first test: the files beside the page it hasn't named,
    /// or that aren't assets, or that climb out, can't be read.
    func testUnrelatedSiblingFilesAreRefused() throws {
        let site = try site()
        XCTAssertNil(site.serve("/other.png"), "a sibling the page never named")
        XCTAssertNil(site.serve("/.env"), "a dotfile")
        XCTAssertNil(site.serve("/secret.env"), "named, but not an asset")
        XCTAssertNil(site.serve("/notes.json"), "named, but not an asset")
        XCTAssertNil(site.serve("/logo.png"), "a symlink to the dotfile beside it")
        XCTAssertNil(site.serve("/away.png"), "a symlink out of the folder")
        XCTAssertNil(site.serve("/../elsewhere/out.png"))
        XCTAssertNil(site.serve("/assets/../.env"))
        XCTAssertNil(site.serve("//index.html"))
    }

    /// The finding's second test: what the page names still loads, styles and
    /// pictures included, and what its stylesheet and script name too.
    func testNamedStylesAndPicturesLoad() throws {
        let site = try site()
        XCTAssertEqual(site.serve("/style.css")?.mimeType, "text/css")
        XCTAssertEqual(site.serve("/pic.png")?.mimeType, "image/png")
        XCTAssertNotNil(site.serve("/assets/pic@2x.png"), "from srcset")
        XCTAssertNotNil(site.serve("/about.html"), "a link to another page")
        XCTAssertNotNil(site.serve("/assets/bg.png"), "named by the stylesheet")
        XCTAssertNotNil(site.serve("/assets/font.woff2"), "named by the stylesheet")
        XCTAssertNil(site.serve("/assets/late.png"), "the script isn't read until it's served")
        XCTAssertNotNil(site.serve("/app.js"))
        XCTAssertNotNil(site.serve("/assets/late.png"), "named by the script")
    }

    /// A stylesheet is only read for names once the page has named it.
    func testNothingIsAllowedBeforeThePageIsServed() throws {
        let site = try XCTUnwrap(LocalPreviewSite(file: dir.appendingPathComponent("index.html")))
        XCTAssertNil(site.serve("/style.css"))
        XCTAssertNil(site.serve("/pic.png"))
    }

    func testResolve() {
        XCTAssertEqual(LocalPreviewSite.resolve("a/b/../c.png", from: ""), "a/c.png")
        XCTAssertEqual(LocalPreviewSite.resolve("../c.png", from: "a"), "c.png")
        XCTAssertNil(LocalPreviewSite.resolve("../c.png", from: ""))
        XCTAssertEqual(LocalPreviewSite.resolve("/c.png", from: "a"), "c.png")
        XCTAssertEqual(LocalPreviewSite.resolve("my%20pic.png#x", from: ""), "my pic.png")
        XCTAssertNil(LocalPreviewSite.resolve("//cdn.example.com/x.png", from: ""))
        XCTAssertNil(LocalPreviewSite.resolve("file:///etc/x.png", from: ""))
        XCTAssertNil(LocalPreviewSite.resolve(".git/x.png", from: ""))
        XCTAssertNil(LocalPreviewSite.resolve("id_rsa", from: ""))
    }

    func testOnlyPagesAndAssetsCanBeTheFile() {
        XCTAssertNil(LocalPreviewSite(file: dir.appendingPathComponent("secret.env")))
        XCTAssertNil(LocalPreviewSite(file: dir.appendingPathComponent(".env")))
    }
}
