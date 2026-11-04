import XCTest
@testable import ThreadbearCore

final class FilePathRefsTests: XCTestCase {
    func testPathShapedCodeIsAPath() {
        for text in ["app/Sources/Threadbear/Transcript/MarkdownRenderer.swift", "TranscriptLinkTests.swift", "CLAUDE.md",
                     "/tmp/a.txt", "~/dev/me/misc", "./check.sh", "../docs/plan.md", "runner/src/", "Foo.swift:12", "Foo.swift:12:4"] {
            XCTAssertTrue(FilePathRefs.looksLikePath(text), text)
        }
        for text in ["./check.sh --app", "http://localhost:5176", "localhost:5176", "example.com", "npm", "tb land",
                     "THREADBEAR_*", "foo()", "v1.2", "/", "1.5", ".gitignore", "a.b.c()", "runner/"] {
            XCTAssertFalse(FilePathRefs.looksLikePath(text), text)
        }
    }

    func testPathsWithSpacesArePaths() {
        for text in ["exports/Threadbear Launch.mp4", "~/Library/Application Support/Threadbear", "/tmp/My Dir/a b.png",
                     "docs/My Notes.md:12", "./My Folder/run.sh"] {
            XCTAssertTrue(FilePathRefs.looksLikePath(text), text)
        }
        // Commands, not paths: a word before the first folder, a flag, a
        // spaced last word with no extension, shell punctuation.
        for text in ["open exports/Threadbear Launch.mp4", "ls runner/src/", "node app/Tools/tour-e2e.mjs", "./check.sh --app",
                     "runner/bin/tb land", "/usr/bin/log show", "cat a/b.txt | head", "a/b.txt > out/c.txt", "My Notes.md",
                     "exports/a  b.mp4", " exports/a.mp4", "exports/a.mp4 ", "a/b\tc.txt"] {
            XCTAssertFalse(FilePathRefs.looksLikePath(text), text)
        }
    }

    func testLineNumbersAreStripped() {
        XCTAssertEqual(FilePathRefs.stripLine("Foo.swift:12"), "Foo.swift")
        XCTAssertEqual(FilePathRefs.stripLine("Foo.swift:12:4"), "Foo.swift")
        XCTAssertEqual(FilePathRefs.stripLine("/tmp/a:b.txt"), "/tmp/a:b.txt")
    }

    func testLinkRoundTrips() throws {
        let text = "app/My Files/a&b.swift:3"
        let url = try XCTUnwrap(FilePathRefs.url(for: text))
        XCTAssertEqual(FilePathRefs.text(of: url), text)
        XCTAssertNil(FilePathRefs.text(of: URL(fileURLWithPath: "/tmp/x")))
    }

    func testResolveOrder() {
        let files: Set<String> = [
            "/home/me/.zshrc", "/repo/app/Sources/A.swift", "/repo/app/Tests/ATests.swift",
            "/other/app/Sources/A.swift", "/work/README.md", "/repo/runner",
        ]
        func resolve(_ text: String, root: String? = "/work", known: [String] = []) -> String? {
            FilePathRefs.resolve(text, root: root, known: known, home: "/home/me", exists: files.contains, search: { _, _ in nil })
        }
        XCTAssertEqual(resolve("~/.zshrc"), "/home/me/.zshrc")
        XCTAssertEqual(resolve("/repo/app/Sources/A.swift:9"), "/repo/app/Sources/A.swift")
        XCTAssertNil(resolve("/nope.swift"))
        XCTAssertEqual(resolve("README.md"), "/work/README.md")
        // The most recent tool path wins.
        XCTAssertEqual(resolve("A.swift", known: ["/other/app/Sources/A.swift", "/repo/app/Sources/A.swift"]), "/repo/app/Sources/A.swift")
        XCTAssertEqual(resolve("Sources/A.swift", known: ["/repo/app/Sources/A.swift", "/other/app/Sources/A.swift"]), "/other/app/Sources/A.swift")
        // Beside a file a tool touched, or inside a folder a command cd-ed into.
        XCTAssertEqual(resolve("ATests.swift", known: ["/repo/app/Tests/Other.swift"]), "/repo/app/Tests/ATests.swift")
        XCTAssertEqual(resolve("app/Tests/ATests.swift", known: ["/repo"]), "/repo/app/Tests/ATests.swift")
        XCTAssertEqual(resolve("runner/", known: ["/repo"]), "/repo/runner")
        XCTAssertNil(resolve("Missing.swift", known: ["/repo"]))
    }

    func testSearchFindsAFileByNameInTheThreadsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = dir.appendingPathComponent("app/Tests/Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("node_modules/x/Only.swift"))
        try Data().write(to: deep.appendingPathComponent("LinkTests.swift"))
        let folder = dir.resolvingSymlinksInPath().path
        let found = try XCTUnwrap(FilePathRefs.resolve("LinkTests.swift:4", root: nil, known: [folder]))
        XCTAssertTrue(found.hasSuffix("/app/Tests/Deep/LinkTests.swift"), found)
        XCTAssertNotNil(FilePathRefs.resolve("Deep/LinkTests.swift", root: folder, known: []))
        XCTAssertNil(FilePathRefs.resolve("Only.swift", root: folder, known: []))
    }

    func testCdTargets() {
        let command = #"cd ~/dev/me/threadbear && git status; (cd "/tmp/My Dir" && ls) || cd relative"#
        XCTAssertEqual(FilePathRefs.cdTargets(command, home: "/home/me"), ["/home/me/dev/me/threadbear", "/tmp/My Dir"])
    }

    func testQueryAndFragmentSplitOff() {
        XCTAssertEqual(FilePathRefs.splitQuery("grow.html?clean&s=45").path, "grow.html")
        XCTAssertEqual(FilePathRefs.splitQuery("grow.html?clean&s=45").query, "clean&s=45")
        XCTAssertNil(FilePathRefs.splitQuery("grow.html?clean&s=45").fragment)
        let both = FilePathRefs.splitQuery("~/a/b.html?x=1#top")
        XCTAssertEqual(both.path, "~/a/b.html")
        XCTAssertEqual(both.query, "x=1")
        XCTAssertEqual(both.fragment, "top")
        // A ? after the # is the fragment's.
        let fragment = FilePathRefs.splitQuery("docs/guide.md#what?")
        XCTAssertEqual(fragment.path, "docs/guide.md")
        XCTAssertNil(fragment.query)
        XCTAssertEqual(fragment.fragment, "what?")
        let plain = FilePathRefs.splitQuery("Foo.swift:12")
        XCTAssertEqual(plain.path, "Foo.swift:12")
        XCTAssertNil(plain.query)
        XCTAssertNil(plain.fragment)
    }

    func testPathsWithAQueryArePaths() {
        for text in ["~/dev/me/misc/threadbear-tree/grow.html?clean&s=45", "site/grow.html?clean", "grow.html#end", "/tmp/a.html?x"] {
            XCTAssertTrue(FilePathRefs.looksLikePath(text), text)
        }
        for text in ["example.com?x=1", "https://example.com/a.html?x=1", "?x=1", "#top"] {
            XCTAssertFalse(FilePathRefs.looksLikePath(text), text)
        }
    }

    func testFileLinkKeepsTheQuery() throws {
        let files: Set<String> = ["/home/me/dev/grow.html", "/work/site/grow.html", "/work/odd?name.txt", "/work/a.swift"]
        func link(_ text: String) -> URL? {
            FilePathRefs.fileLink(text, root: "/work", known: [], home: "/home/me", exists: files.contains, search: { _, _ in nil })
        }
        let grow = try XCTUnwrap(link("~/dev/grow.html?clean&s=45"))
        XCTAssertTrue(grow.isFileURL)
        XCTAssertEqual(grow.path, "/home/me/dev/grow.html")
        XCTAssertEqual(grow.query, "clean&s=45")
        XCTAssertEqual(grow.absoluteString, "file:///home/me/dev/grow.html?clean&s=45")
        XCTAssertEqual(try XCTUnwrap(link("site/grow.html#end")).absoluteString, "file:///work/site/grow.html#end")
        // Escaping is kept as written, not done twice.
        XCTAssertEqual(try XCTUnwrap(link("site/grow.html?t=a%20b")).absoluteString, "file:///work/site/grow.html?t=a%20b")
        // A file whose name has a ? in it is that file, not a query.
        let odd = try XCTUnwrap(link("odd?name.txt"))
        XCTAssertEqual(odd.path, "/work/odd?name.txt")
        XCTAssertNil(odd.query)
        // Plain paths and line numbers as before.
        XCTAssertEqual(link("a.swift:3"), URL(fileURLWithPath: "/work/a.swift"))
        XCTAssertNil(link("missing.html?x"))
    }

    func testForwardingPageGoesToTheLink() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/a%20b/grow.html?clean&s=45#x"))
        let page = FilePathRefs.forwardingPage(to: url)
        XCTAssertTrue(page.contains(#"location.replace("file:\/\/\/tmp\/a%20b\/grow.html?clean&s=45#x")"#), page)
        // Nothing in the link can end the script early.
        let sneaky = try XCTUnwrap(URL(string: "file:///tmp/a.html?\"</script>"))
        XCTAssertEqual(FilePathRefs.forwardingPage(to: sneaky).components(separatedBy: "</script>").count, 2)
    }
}
