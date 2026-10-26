import XCTest
@testable import ThreadbareCore

/// What an expanded tool shows, and the titles a live group uses.
final class ToolDetailTests: XCTestCase {
    func tool(_ name: String, _ kind: ToolKind, title: String = "t", input: [String: JSONValue], result: String? = nil, ok: Bool = true) -> ToolItem {
        ToolItem(itemId: "c1", call: ToolCall(itemId: "c1", name: name, kind: kind, title: title, input: .object(input)),
                 result: result.map { ToolResult(itemId: "c1", ok: ok, text: $0) })
    }

    func testACommandShowsTheCommandThenItsOutput() {
        let detail = ToolPresentation.detail(tool("Bash", .command, input: ["command": .string("npm test")], result: "12 passed\n"))
        XCTAssertEqual(detail, .command(command: "npm test", output: "12 passed"))
    }

    func testAReadKeepsClaudesLineNumbers() {
        let read = tool("Read", .read, input: ["file_path": .string("/a.swift")], result: "     9→import Foundation\n    10→\n    11→let x = 1")
        guard case .file(let path, let lines) = ToolPresentation.detail(read) else { return XCTFail() }
        XCTAssertEqual(path, "/a.swift")
        XCTAssertEqual(lines.map(\.number), [9, 10, 11])
        XCTAssertEqual(lines.map(\.text), ["import Foundation", "", "let x = 1"])
    }

    func testAReadWithoutNumbersIsNumberedFromItsOffset() {
        let read = tool("Read", .read, input: ["file_path": .string("/a.swift"), "offset": .number(40)], result: "a\nb")
        guard case .file(_, let lines) = ToolPresentation.detail(read) else { return XCTFail() }
        XCTAssertEqual(lines, [.init(number: 40, text: "a"), .init(number: 41, text: "b")])
    }

    func testAFailedReadShowsItsInputAndError() {
        let read = tool("Read", .read, input: ["file_path": .string("/missing")], result: "File does not exist.", ok: false)
        XCTAssertEqual(ToolPresentation.detail(read), .fields(fields: [.init(key: "file_path", value: "/missing")], output: "File does not exist."))
    }

    func testASearchShowsTheQueryAndWhere() {
        let search = tool("Grep", .search, input: ["pattern": .string("class Upload"), "path": .string("Sources")], result: "a.swift:1:class Upload")
        XCTAssertEqual(ToolPresentation.detail(search), .search(query: "class Upload", scope: "Sources", output: "a.swift:1:class Upload"))
    }

    func testOtherToolsShowTheirInputAsFieldsNotJSON() {
        let other = tool("mcp__notion__search", .mcp, input: [
            "query": .string("roadmap"), "limit": .number(5), "filter": .object(["type": .string("page")]), "cursor": .null,
        ], result: "3 pages")
        XCTAssertEqual(ToolPresentation.detail(other), .fields(fields: [
            .init(key: "filter", value: "{\"type\":\"page\"}"), .init(key: "limit", value: "5"), .init(key: "query", value: "roadmap"),
        ], output: "3 pages"))
    }

    func testLongFieldValuesAreCut() {
        let long = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let fields = ToolPresentation.fields(.object(["text": .string(long)]))
        XCTAssertEqual(fields.first?.value.split(separator: "\n").count, 7, "six lines and an ellipsis")
    }

    func testLiveTitles() {
        XCTAssertEqual(ToolPresentation.activeTitle(tool("Bash", .command, title: "npm test", input: ["command": .string("npm test")])), "Running npm test")
        XCTAssertEqual(ToolPresentation.activeTitle(tool("Bash", .command, title: "Run the tests", input: ["command": .string("npm test")])), "Run the tests")
        XCTAssertEqual(ToolPresentation.activeTitle(tool("Read", .read, title: "Read a.swift", input: [:])), "Read a.swift")
    }

    func testExportsOfDerivedRows() {
        let group = TranscriptRow(id: "g:t:c1", seq: 1, content: .group(WorkGroup(memberIds: ["t:c1", "t:c2"], summary: "Ran 2 commands")))
        XCTAssertEqual(MarkdownExport.message(for: group), "_Ran 2 commands_")
        let card = TranscriptRow(id: "cf:t1", seq: 2, content: .changes(ChangedFiles(turnId: "t1", files: [
            ChangedFile(path: "/a.swift", added: 3, removed: 1, diffs: []),
        ])))
        XCTAssertEqual(MarkdownExport.message(for: card), "Edited 1 file:\n- `/a.swift` +3 −1")
        XCTAssertNil(MarkdownExport.message(for: TranscriptRow(id: "w:t1", seq: 3, content: .working(WorkingStatus(turnId: "t1", startedAt: nil)))))
    }
}
