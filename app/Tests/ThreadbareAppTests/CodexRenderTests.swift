import AppKit
import XCTest
@testable import Threadbare
@testable import ThreadbareCore

/// How Codex turns draw: a footer with the time only, an approval's reason
/// under its title, and a generated image bigger than a screenshot.
@MainActor
final class CodexRenderTests: XCTestCase {
    func testCodexFooterIsTheDurationOnly() {
        let codex = TurnCompletion(turnId: "t1", outcome: .completed, durationMs: 12_400,
                                   usage: .object(["inputTokens": .number(24177), "outputTokens": .number(310)]))
        XCTAssertEqual(RowRenderer.footerText(codex).string, "12s", "Codex reports no cost, and its tokens are in Copy debug info")
        let claude = TurnCompletion(turnId: "t1", outcome: .completed, durationMs: 12_400, costUsd: 0.04)
        XCTAssertEqual(RowRenderer.footerText(claude).string, "12s · $0.04", "Claude's footer doesn't change")
    }

    func testApprovalCardShowsCodexsReason() {
        let request = ApprovalRequest(approvalId: "ap1", itemId: "c1", name: "shell", title: "touch b.txt",
                                      input: .object(["command": .string("touch b.txt"), "reason": .string("Allow creating b.txt in the current directory?")]))
        let title = RowRenderer.approvalTitleText(ApprovalItem(request: request)).string
        XCTAssertTrue(title.hasSuffix("\nAllow creating b.txt in the current directory?"), title)
    }

    func testAGeneratedImageIsShownLargerThanAScreenshot() {
        let image = ImageRef(path: "/m/poster.png", mediaType: "image/png", width: 1254, height: 1254)
        let measurer = TextMeasurer()
        let generated = RowRenderer.render(TranscriptRow(id: "i:a", seq: 1, content: .images(itemId: "a", images: [image], generated: true)),
                                           expanded: false, tableWidth: 1000, measurer: measurer)
        let screenshot = RowRenderer.render(TranscriptRow(id: "i:b", seq: 1, content: .images(itemId: "b", images: [image])),
                                            expanded: false, tableWidth: 1000, measurer: measurer)
        XCTAssertEqual(generated.imageFrames.first?.width, ImageLayout.generatedMaxSide)
        XCTAssertEqual(screenshot.imageFrames.first?.height, RowMetrics.gridMaxHeight)
    }

    /// An expanded patch names each file over its lines; edits to one file
    /// don't get a name each.
    func testAMultiFileDiffNamesEachFile() {
        func diff(_ path: String, _ lines: [String]) -> EditDiff {
            EditDiff(itemId: "p1", path: path, hunks: [DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: lines.count, lines: lines)])
        }
        let diffs = [diff("/w/site/fruits.txt", ["+dates"]), diff("/w/notes.txt", ["-Line two.", "+Line two, edited."])]
        let text = RowRenderer.diffText(diffs, maxLines: 100, root: "/w").0.string
        XCTAssertTrue(text.hasPrefix("fruits.txt  site  +1 −0\n"), text)
        XCTAssertTrue(text.contains("\nnotes.txt  +1 −1\n"), text)
        XCTAssertFalse(text.contains("⋯"), "a name, not a break, between files")
        let oneFile = RowRenderer.diffText([diff("/w/a.txt", ["+a"]), diff("/w/a.txt", ["+b"])], maxLines: 100, root: "/w").0.string
        XCTAssertFalse(oneFile.contains("a.txt"), "two edits to one file stay as they were")
    }

    func testAGeneratedImagesPromptIsProse() {
        let call = ToolCall(itemId: "ig", name: "image_generation", kind: .image, title: "Generate image")
        let tool = ToolItem(itemId: "ig", call: call, result: ToolResult(itemId: "ig", ok: true, text: "A small, simple flat blue circle"))
        let body = RowRenderer.toolBody(tool)
        XCTAssertEqual(body.string, "A small, simple flat blue circle")
        let font = body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font?.isFixedPitch ?? true, "the reading font, not the output's monospace")
    }

    func testErrorRowSaysWhatToDoWhenTheRunnerKnowsWhy() {
        let row = TranscriptRow(id: "e:1", seq: 1, content: .error("Context window exceeded", kind: .contextWindow))
        let text = RowRenderer.render(row, expanded: false, tableWidth: 900, measurer: TextMeasurer()).text?.string ?? ""
        XCTAssertEqual(text, "Context window exceeded\nThe conversation is too long for this model. Start a new thread to carry on.")
    }
}
