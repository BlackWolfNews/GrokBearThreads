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

    func testErrorRowSaysWhatToDoWhenTheRunnerKnowsWhy() {
        let row = TranscriptRow(id: "e:1", seq: 1, content: .error("Context window exceeded", kind: .contextWindow))
        let text = RowRenderer.render(row, expanded: false, tableWidth: 900, measurer: TextMeasurer()).text?.string ?? ""
        XCTAssertEqual(text, "Context window exceeded\nThe conversation is too long for this model. Start a new thread to carry on.")
    }
}
