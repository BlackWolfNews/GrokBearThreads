import XCTest
@testable import ThreadbearCore

/// Words for cards, folders relative to the thread, tool field columns,
/// error lines, the sidebar's running time and image rows.
final class CardTextTests: XCTestCase {
    func approval(_ name: String, _ input: [String: JSONValue], title: String = "t") -> ApprovalRequest {
        ApprovalRequest(approvalId: "ap1", name: name, title: title, input: .object(input))
    }

    // MARK: Approvals

    func testApprovalTitlesAndTargets() {
        let write = approval("Write", ["file_path": .string("/Users/mike/dev/photo-sync/scripts/release.sh"), "content": .string("x")])
        XCTAssertEqual(ApprovalText.title(write), "Write release.sh?")
        XCTAssertEqual(ApprovalText.target(write), "Write release.sh")
        let bash = approval("Bash", ["command": .string("rm -rf .build DerivedData\necho done")])
        XCTAssertEqual(ApprovalText.title(bash), "Run this command?")
        XCTAssertEqual(ApprovalText.target(bash), "rm -rf .build DerivedData", "a command is named by its first line")
        let mcp = approval("mcp__github__get_pull_request", ["pullNumber": .number(48)])
        XCTAssertEqual(ApprovalText.title(mcp), "Use get pull request?")
        XCTAssertEqual(ApprovalText.target(approval("WebFetch", ["url": .string("https://example.com")])), "Fetch https://example.com")
        XCTAssertEqual(ApprovalText.target(approval("Edit", [:])), "Edit this file")
        XCTAssertEqual(ApprovalText.decision(.allowAlways), "Always allowed")
    }

    func testAnswersReadInTheOrderTheQuestionsWereAsked() {
        let request = QuestionRequest(approvalId: "q1", questions: [
            Question(question: "Which colour?", options: [QuestionOption(label: "Blue")]),
            Question(question: "Which size?", options: [QuestionOption(label: "Small")]),
        ])
        XCTAssertEqual(ApprovalText.answerSummary(request, answers: ["Which size?": "Small", "Which colour?": "Blue"]), "Blue; Small")
        XCTAssertEqual(ApprovalText.answerSummary(request, answers: ["Which colour?": "Green, Blue"]), "Green, Blue")
        XCTAssertEqual(ApprovalText.answerSummary(request, answers: [:]), "")
    }

    // MARK: Plans

    func testPlanTitles() {
        func entries(_ statuses: [PlanStatus]) -> [PlanEntry] { statuses.map { PlanEntry(text: "x", status: $0) } }
        XCTAssertEqual(PlanSummary.title(entries([.completed, .completed, .in_progress, .pending, .pending])), "2 of 5 steps done")
        XCTAssertEqual(PlanSummary.title(entries([.completed, .completed, .completed])), "All 3 steps done")
        XCTAssertEqual(PlanSummary.title(entries([.completed])), "1 step done")
        XCTAssertEqual(PlanSummary.title(entries([.pending])), "0 of 1 step done")
        XCTAssertEqual(PlanSummary.title([]), "No steps yet")
    }

    // MARK: Folders

    func testFoldersAreRelativeToTheThreadsFolder() {
        let root = "/Users/mike/dev/photo-sync"
        XCTAssertEqual(PathDisplay.folder(of: root + "/scripts/release.sh", relativeTo: root), "scripts")
        XCTAssertEqual(PathDisplay.folder(of: root + "/Sources/Upload/UploadTask.swift", relativeTo: root + "/"), "Sources/Upload")
        XCTAssertEqual(PathDisplay.folder(of: root + "/Package.swift", relativeTo: root), "", "a file at the top has no folder")
        // Outside the thread's folder, or no folder: as before.
        XCTAssertEqual(PathDisplay.folder(of: "/Users/mike/dev/other/Sources/a.swift", relativeTo: root), "other/Sources")
        XCTAssertEqual(PathDisplay.folder(of: root + "-old/a.swift", relativeTo: root), "dev/photo-sync-old", "a sibling with the same prefix is outside")
        XCTAssertEqual(PathDisplay.folder(of: root + "/scripts/release.sh", relativeTo: nil), "photo-sync/scripts")
        XCTAssertEqual(PathDisplay.folder(of: NSHomeDirectory() + "/dev/x/a.txt", relativeTo: "~/dev"), "x")
        XCTAssertNil(PathDisplay.relativePath("/a.txt", to: "/"))
    }

    func testFileRowsAndTheChangesCardUseTheThreadsFolder() {
        let root = "/Users/mike/dev/photo-sync"
        let path = root + "/scripts/release.sh"
        let model = TranscriptModel(events: [
            E.user(1, "Go"),
            E.call(2, "w", name: "Write", kind: "write", title: "Write", input: ["file_path": path, "content": "echo hi\n"]),
            E.result(3, "w"), E.done(4),
        ], root: root)
        guard case .tool(let tool)? = model.item(id: "t:w")?.content else { return XCTFail() }
        XCTAssertEqual(ToolPresentation.fileTitle(tool)?.folder, "scripts")
        guard case .changes(let card)? = model.row(id: "cf:t1")?.content else { return XCTFail() }
        XCTAssertEqual(card.files.first?.folder, "scripts")
    }

    // MARK: Tool details

    func testFieldKeysLineUpUpToACap() {
        let fields = [ToolPresentation.Field(key: "owner", value: "mike"), .init(key: "pullNumber", value: "48"), .init(key: "repo", value: "photo-sync")]
        XCTAssertEqual(ToolPresentation.keyWidth(fields), 11, "\"pullNumber:\" is the widest")
        let long = fields + [.init(key: "a_really_long_parameter_name", value: "x")]
        XCTAssertEqual(ToolPresentation.keyWidth(long), 16, "a long key doesn't push every value right")
        XCTAssertEqual(ToolPresentation.keyWidth(long, cap: 20), 20)
        XCTAssertEqual(ToolPresentation.keyWidth([]), 0)
    }

    func testErrorLines() {
        XCTAssertTrue(ToolPresentation.isErrorLine("error: SIGNING_IDENTITY is not set"))
        XCTAssertTrue(ToolPresentation.isErrorLine("Error: Cannot find module"))
        XCTAssertTrue(ToolPresentation.isErrorLine("  fatal: not a git repository"))
        XCTAssertTrue(ToolPresentation.isErrorLine("ERROR [build 3/7] failed"))
        XCTAssertFalse(ToolPresentation.isErrorLine("Building for production..."))
        XCTAssertFalse(ToolPresentation.isErrorLine("errors.swift compiled"))
        XCTAssertFalse(ToolPresentation.isErrorLine("0 errors"))
        XCTAssertFalse(ToolPresentation.isErrorLine("error"))
    }

    // MARK: Sidebar

    func testRunningTimes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ThreadRowLook.workingLabel(since: start, now: start.addingTimeInterval(53)), "53s")
        XCTAssertEqual(ThreadRowLook.workingLabel(since: start, now: start.addingTimeInterval(4 * 60 + 59)), "4m")
        XCTAssertEqual(ThreadRowLook.workingLabel(since: start, now: start.addingTimeInterval(62 * 60)), "1h 2m")
        XCTAssertEqual(ThreadRowLook.workingLabel(since: start, now: start.addingTimeInterval(2 * 3600)), "2h")
        XCTAssertEqual(ThreadRowLook.workingLabel(since: start, now: start.addingTimeInterval(-5)), "0s", "a clock that's a little behind")
    }

    func testHoverActionsAskBeforeStoppingATurn() {
        func thread(_ status: ThreadStatus, background: [BackgroundTask] = []) -> ThreadSummary {
            ThreadSummary(id: "t", title: "t", status: status, background: background)
        }
        XCTAssertTrue(BusyThreadAction.needsConfirm(thread(.running)))
        XCTAssertTrue(BusyThreadAction.needsConfirm(thread(.starting)))
        XCTAssertTrue(BusyThreadAction.needsConfirm(thread(.waiting)))
        XCTAssertFalse(BusyThreadAction.needsConfirm(thread(.idle)))
        XCTAssertFalse(BusyThreadAction.needsConfirm(thread(.error)))
        XCTAssertEqual(BusyThreadAction.prompt(.archive, thread: thread(.running)).title, "Archive and stop the turn?")
        XCTAssertEqual(BusyThreadAction.prompt(.snooze, thread: thread(.waiting)).detail, "This thread is waiting for you. Hibernating it now stops its turn.")
        // Background sub-agents or jobs are stopped too when the CLI is let go.
        let cubs = thread(.idle, background: [BackgroundTask(kind: .agent, description: "a"), BackgroundTask(kind: .agent, description: "b")])
        XCTAssertTrue(BusyThreadAction.needsConfirm(cubs))
        XCTAssertEqual(BusyThreadAction.prompt(.archive, thread: cubs).title, "Archive and stop the background work?")
        XCTAssertEqual(BusyThreadAction.prompt(.snooze, thread: cubs).detail, "This thread still has 2 sub-agents in the background. Hibernating it now stops them.")
    }

    // MARK: Images

    func testImagesInARowShareOneHeight() {
        // A 900x560 screenshot and a 760x420 chart, both fitted to 320x240.
        let result = ImageLayout.frames(sizes: [CGSize(width: 900, height: 560), CGSize(width: 760, height: 420)],
                                        maxWidth: 780, maxHeight: 240, cellWidth: 320, gap: 8, alignRight: false)
        XCTAssertEqual(result.frames.map(\.height), [176, 176])
        XCTAssertEqual(result.frames[0], CGRect(x: 0, y: 0, width: 283, height: 176), "the taller one shrinks, keeping its shape")
        XCTAssertEqual(result.frames[1], CGRect(x: 291, y: 0, width: 320, height: 176))
        XCTAssertEqual(result.height, 176)
    }

    func testRightAlignedRowsAndWrapping() {
        let sizes = [CGSize(width: 400, height: 400), CGSize(width: 800, height: 400), CGSize(width: 300, height: 600)]
        let result = ImageLayout.frames(sizes: sizes, maxWidth: 400, maxHeight: 120, cellWidth: 320, gap: 8, alignRight: true)
        // 120x120 and 240x120 share the first row; the tall one wraps.
        XCTAssertEqual(result.frames[0], CGRect(x: 32, y: 0, width: 120, height: 120))
        XCTAssertEqual(result.frames[1], CGRect(x: 160, y: 0, width: 240, height: 120))
        XCTAssertEqual(result.frames[2], CGRect(x: 340, y: 128, width: 60, height: 120))
        XCTAssertEqual(result.height, 248)
        // One image on its own keeps its fitted size.
        let one = ImageLayout.frames(sizes: [CGSize(width: 100, height: 50)], maxWidth: 400, maxHeight: 240, cellWidth: 320, gap: 8, alignRight: false)
        XCTAssertEqual(one.frames, [CGRect(x: 0, y: 0, width: 100, height: 50)])
    }
}
