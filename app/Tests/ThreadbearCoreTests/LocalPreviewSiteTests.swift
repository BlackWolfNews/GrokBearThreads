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
        <script>fetch("private.html"); const p = 'assets/inline.png'; document.body.style.background = "url(assets/js.png)";</script>
        <div style="background: url('assets/styled.png')"></div>
        """)
        try write("style.css", "@import 'theme.css'; body { background: url('assets/bg.png'); } @font-face { src: url(assets/font.woff2) }")
        try write("app.js", "const img = new Image(); img.src = `assets/late.png`;")
        try write("theme.css", "a { color: red }")
        for name in ["pic.png", "assets/pic@2x.png", "assets/bg.png", "assets/font.woff2", "assets/late.png", "about.html", "other.png", "notes.json",
                     "private.html", "assets/inline.png", "assets/js.png", "assets/styled.png"] {
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
        XCTAssertNotNil(site.serve("/assets/bg.png"), "named by the stylesheet")
        XCTAssertNotNil(site.serve("/assets/font.woff2"), "named by the stylesheet")
        XCTAssertNotNil(site.serve("/theme.css"), "an @import")
        XCTAssertNotNil(site.serve("/assets/styled.png"), "a style attribute's url()")
    }

    /// The last verify-fix round: only the selected page and passive assets
    /// (styles, pictures, fonts, sound and video) are ever served. Another
    /// page or a script is refused even when the page names it, as an
    /// iframe or a script src, and so is SVG, which can carry script.
    func testOnlyThePageItselfAndPassiveAssets() throws {
        try write("drawing.svg", "<svg xmlns='http://www.w3.org/2000/svg'><script>1</script></svg>")
        try write("index.html", "<iframe src=about.html></iframe><iframe src=private.html></iframe><script src=app.js></script><img src=drawing.svg><img src=pic.png>")
        let site = try site()
        XCTAssertNil(site.serve("/about.html"))
        XCTAssertNil(site.serve("/private.html"))
        XCTAssertNil(site.serve("/app.js"))
        XCTAssertNil(site.serve("/drawing.svg"))
        XCTAssertNotNil(site.serve("/pic.png"))
        XCTAssertNotNil(site.serve("/index.html"), "the page itself, again")
    }

    /// The verify-fix round: only markup's src and href (and srcset, poster,
    /// style url()) and a stylesheet's url() and @import name a file. A
    /// string in a script names nothing, so `fetch("private.html")` can't
    /// let a page read the page beside it.
    func testScriptsNameNothing() throws {
        let site = try site()
        XCTAssertNil(site.serve("/private.html"), "fetch() in an inline script")
        XCTAssertNil(site.serve("/assets/inline.png"), "a quoted string in an inline script")
        XCTAssertNil(site.serve("/assets/js.png"), "url() inside a script")
        XCTAssertNil(site.serve("/assets/late.png"), "named in a script file")
    }

    /// Codex's review: no symlink is followed anywhere on the way, not even
    /// to an allowed picture inside the folder, and a file swapped for a link
    /// after it was first served reads nothing.
    func testNoSymlinkIsFollowed() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outside.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "far".write(to: outside.appendingPathComponent("assets/bg.png"), atomically: true, encoding: .utf8)
        try write("index.html", "<img src=pic.png><img src=alias.png><img src=linked/bg.png><img src=hard.png>")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("alias.png"), withDestinationURL: dir.appendingPathComponent("pic.png"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: outside.appendingPathComponent("assets"))
        try fm.linkItem(at: outside.appendingPathComponent("out.png"), to: dir.appendingPathComponent("hard.png"))
        let site = try site()
        XCTAssertNil(site.serve("/alias.png"), "a link, even to an allowed picture")
        XCTAssertNil(site.serve("/linked/bg.png"), "a folder on the way that's a link")
        XCTAssertNil(site.serve("/hard.png"), "a hard link to a file elsewhere")
        XCTAssertEqual(site.serve("/pic.png")?.data, Data("x".utf8))
        // Swapped for a link to the secret beside it, after being served once.
        try fm.removeItem(at: dir.appendingPathComponent("pic.png"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("pic.png"), withDestinationURL: dir.appendingPathComponent(".env"))
        XCTAssertNil(site.serve("/pic.png"))
    }

    /// Codex's second review: a NUL in a name passed the extension check
    /// (`credentials.json\0.html` ends in .html) and then `openat` stopped
    /// at the NUL and opened `credentials.json`. Control characters and
    /// names still percent-encoded after decoding are refused outright.
    func testNulAndControlCharactersAreRefused() throws {
        try write("credentials.json", "{\"key\": \"secret\"}")
        try write("index.html", #"<iframe src="credentials.json%00.html"></iframe><img src="a%0Ab.png"><img src="x%2500.png">"#)
        let site = try site()
        XCTAssertNil(site.serve("/credentials.json\u{0}.html"))
        XCTAssertNil(site.serve("/a\nb.png"))
        XCTAssertNil(site.serve("/x%00.png"))
        XCTAssertNil(site.serve("/credentials.json"))
        XCTAssertNil(LocalPreviewSite.resolve("credentials.json%00.html", from: ""))
        XCTAssertNil(LocalPreviewSite.resolve("a%7Fb.png", from: ""))
        XCTAssertNil(LocalPreviewSite.resolve("x%2500.png", from: ""))
        XCTAssertNil(LocalPreviewSite.safeParts("a\u{0}.html"))
        XCTAssertNil(LocalPreviewSite.safeParts("a\u{85}.png"))
        XCTAssertNotNil(LocalPreviewSite.safeParts("my pic.png"))
    }

    /// A FIFO named like a picture is refused without hanging the open.
    func testAFifoIsRefused() throws {
        try write("index.html", "<img src=pipe.png>")
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("pipe.png").path, 0o600), 0)
        let site = try site()
        XCTAssertNil(site.serve("/pipe.png"))
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
        XCTAssertNil(LocalPreviewSite(file: dir.appendingPathComponent("app.js")), "only a page is a page")
        XCTAssertNil(LocalPreviewSite(file: dir.appendingPathComponent("pic.png")))
    }

    func testHasScripts() {
        XCTAssertTrue(LocalPreviewSite.hasScripts(Data("<p>x</p><script>draw()</script>".utf8)))
        XCTAssertTrue(LocalPreviewSite.hasScripts(Data("<SCRIPT src=app.js></SCRIPT>".utf8)))
        XCTAssertFalse(LocalPreviewSite.hasScripts(Data("<p>A script-free mockup</p>".utf8)))
        XCTAssertFalse(LocalPreviewSite.hasScripts(Data()))
        XCTAssertTrue(LocalPreviewSite.hasScripts(Data("<body onload=\"draw()\">".utf8)))
        XCTAssertTrue(LocalPreviewSite.hasScripts(Data("<body\n  onload = \"draw()\">".utf8)))
        XCTAssertFalse(LocalPreviewSite.hasScripts(Data("<p>Do it once = twice</p>".utf8)), "words, not a handler")
        XCTAssertTrue(LocalPreviewSite.hasScripts(Data("<a href=\"javascript:go()\">go</a>".utf8)))
    }

    func testScanNeverBlocksOnAFifo() throws {
        let page = dir.appendingPathComponent("drawn.html")
        try Data("<script>draw()</script>".utf8).write(to: page)
        let scan = try XCTUnwrap(LocalPreviewSite.scan(atPath: page.path))
        XCTAssertTrue(scan.scripts)
        XCTAssertEqual(scan.digest, LocalPreviewSite.digest(Data("<script>draw()</script>".utf8)))
        let fifo = dir.appendingPathComponent("pipe.html").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertNil(LocalPreviewSite.scan(atPath: fifo), "returns at once, with no writer")
        XCTAssertNil(LocalPreviewSite.scan(atPath: dir.appendingPathComponent("gone.html").path))
    }

    /// A view running the page's scripts is served the page only while its
    /// bytes are the ones Mike allowed: rewritten after Run them, nothing.
    func testAPageWithADigestIsServedOnlyWhileItMatches() throws {
        let page = dir.appendingPathComponent("drawn.html")
        try Data("<script>draw()</script>".utf8).write(to: page)
        let digest = LocalPreviewSite.digest(Data("<script>draw()</script>".utf8))
        let site = try XCTUnwrap(LocalPreviewSite(file: page, pageDigest: digest))
        XCTAssertNotNil(site.serve("drawn.html"))
        try Data("<script>steal()</script>".utf8).write(to: page)
        XCTAssertNil(site.serve("drawn.html"), "rewritten: not what was allowed")
        XCTAssertNil(LocalPreviewSite(file: page, pageDigest: digest)?.serve("drawn.html"))
        XCTAssertNotNil(LocalPreviewSite(file: page)?.serve("drawn.html"), "the static view still shows it")
    }

    func testConsentIsForThoseBytesOfThatFile() {
        let defaults = UserDefaults(suiteName: "LocalPreviewSiteTests.\(UUID().uuidString)")!
        let consent = PreviewScriptConsent(defaults: defaults)
        XCTAssertFalse(consent.allows(path: "/a/page.html", digest: "1"))
        consent.allow(path: "/a/page.html", digest: "1")
        XCTAssertTrue(consent.allows(path: "/a/page.html", digest: "1"))
        XCTAssertFalse(consent.allows(path: "/a/page.html", digest: "2"), "changed")
        XCTAssertFalse(consent.allows(path: "/b/page.html", digest: "1"), "another file with the same bytes")
        consent.allow(path: "/a/page.html", digest: "2")
        XCTAssertFalse(consent.allows(path: "/a/page.html", digest: "1"), "one version per file")
    }
}
