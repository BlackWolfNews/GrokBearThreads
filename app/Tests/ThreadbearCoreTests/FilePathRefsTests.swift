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
}
