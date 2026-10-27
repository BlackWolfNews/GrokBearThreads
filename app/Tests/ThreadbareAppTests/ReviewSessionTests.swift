import XCTest
@testable import Threadbare
import ThreadbareCore

@MainActor
final class ReviewSessionTests: XCTestCase {
    func review() -> DesignReview {
        DesignReview(id: "review", title: "Account picker", options: [
            ReviewOption(id: "A", title: "Auto", image: ImageRef(path: "/tmp/a.png", mediaType: "image/png")),
            ReviewOption(id: "B", title: "One picker", image: ImageRef(path: "/tmp/b.png", mediaType: "image/png")),
        ])
    }

    func cache() -> UserDefaults { UserDefaults(suiteName: "ReviewTests.\(UUID().uuidString)")! }

    func testAnEditDuringSaveIsKeptForTheNextSave() async {
        var server = review()
        var finish: CheckedContinuation<Void, Never>?
        let service = ReviewService(load: { server }, save: { revision, draft in
            await withCheckedContinuation { finish = $0 }
            server.revision = revision + 1
            server.draft = draft
            return server
        }, respond: { _, _ in server }, cancel: { _ in server })
        let session = ReviewSession(threadId: "thread", review: server, service: service, defaults: cache(), autosave: false)
        session.setNote("First", for: "A")
        let saving = Task { await session.saveNow() }
        while finish == nil { await Task.yield() }
        session.setNote("Second", for: "A")
        finish?.resume()
        await saving.value
        XCTAssertEqual(session.draft.notes["A"], "Second")
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(session.review.revision, 2)
    }

    func testFailedSaveSurvivesReopeningWithoutReplacingNewServerRevision() async {
        let defaults = cache()
        var server = review()
        let service = ReviewService(load: { server }, save: { _, _ in throw NSError(domain: "offline", code: 1) }, respond: { _, _ in server }, cancel: { _ in server })
        let session = ReviewSession(threadId: "thread", review: server, service: service, defaults: defaults, autosave: false)
        session.setNote("Keep this text", for: "B")
        await session.saveNow()
        XCTAssertTrue(session.dirty)
        XCTAssertNotNil(session.error)
        server.revision = 3
        let reopened = ReviewSession(threadId: "thread", review: server, service: service, defaults: defaults, autosave: false)
        XCTAssertEqual(reopened.draft.notes["B"], "Keep this text")
        XCTAssertEqual(reopened.review.revision, 3)
        XCTAssertTrue(reopened.conflict)
    }

    func testNotesOnlySubmissionSendsOnceAndBecomesReadOnly() async {
        var server = review()
        var replies = 0
        let service = ReviewService(load: { server }, save: { _, draft in server.draft = draft; server.revision += 1; return server }, respond: { _, draft in
            replies += 1
            server.status = "answered"
            server.response = draft
            server.draft = draft
            server.revision += 1
            return server
        }, cancel: { _ in server })
        let session = ReviewSession(threadId: "thread", review: server, service: service, defaults: cache(), autosave: false)
        XCTAssertFalse(session.canSubmit)
        session.setNote("Try a version with a smaller menu", for: "A")
        XCTAssertTrue(session.canSubmit)
        await session.submit()
        await session.submit()
        session.setNote("Cannot edit an answer", for: "A")
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(session.review.response?.notes["A"], "Try a version with a smaller menu")
        XCTAssertFalse(session.review.isPending)
        XCTAssertFalse(session.dirty)
    }

    func testExternalAnswerKeepsUnsavedTextAvailableWithoutResubmitting() async {
        var server = review()
        let service = ReviewService(load: { server }, save: { _, _ in server }, respond: { _, _ in server }, cancel: { _ in server })
        let session = ReviewSession(threadId: "thread", review: server, service: service, defaults: cache(), autosave: false)
        session.setNote("My draft", for: "A")
        server.status = "answered"
        server.revision = 2
        server.response = ReviewDraft(pickedId: "B")
        session.receive(server)
        XCTAssertEqual(session.draft.notes["A"], "My draft")
        XCTAssertFalse(session.canSubmit)
        XCTAssertNotNil(session.error)
    }

    func testServerTrimmingDoesNotLeaveTheDraftDirty() async {
        var server = review()
        let service = ReviewService(load: { server }, save: { _, _ in
            server.draft = ReviewDraft(notes: ["A": "A note"])
            server.revision += 1
            return server
        }, respond: { _, _ in server }, cancel: { _ in server })
        let session = ReviewSession(threadId: "thread", review: server, service: service, defaults: cache(), autosave: false)
        session.setNote("A note  ", for: "A")
        session.setNote("  ", for: "B")
        await session.saveNow()
        XCTAssertFalse(session.dirty)
    }

    func testNewerRemoteDraftWinsRevisionWhileUnsentTextRemainsInConflict() async {
        let initial = review()
        var finish: CheckedContinuation<DesignReview, Never>?
        let service = ReviewService(load: { initial }, save: { _, _ in await withCheckedContinuation { finish = $0 } }, respond: { _, _ in initial }, cancel: { _ in initial })
        let defaults = cache()
        let session = ReviewSession(threadId: "thread", review: initial, service: service, defaults: defaults, autosave: false)
        session.setNote("Mine", for: "A")
        let saving = Task { await session.saveNow() }
        while finish == nil { await Task.yield() }
        var remote = initial
        remote.revision = 3
        remote.draft = ReviewDraft(notes: ["A": "Theirs"])
        session.receive(remote)
        var acknowledgement = initial
        acknowledgement.revision = 2
        acknowledgement.draft = ReviewDraft(notes: ["A": "Mine"])
        finish?.resume(returning: acknowledgement)
        await saving.value
        XCTAssertEqual(session.review.revision, 3)
        XCTAssertEqual(session.draft.notes["A"], "Mine")
        XCTAssertTrue(session.dirty)
        XCTAssertTrue(session.conflict)
        XCTAssertFalse(session.canSubmit)
        let reopened = ReviewSession(threadId: "thread", review: remote, service: service, defaults: defaults, autosave: false)
        XCTAssertTrue(reopened.conflict)
    }

    func testAStaleSubmitCannotSilentlyOverwriteAnotherWindowsDraft() async {
        var remote = review()
        var finish: CheckedContinuation<Void, Never>?
        let service = ReviewService(load: { remote }, save: { _, _ in remote }, respond: { _, _ in
            await withCheckedContinuation { finish = $0 }
            throw NSError(domain: "stale revision", code: 1)
        }, cancel: { _ in remote })
        let session = ReviewSession(threadId: "thread", review: remote, service: service, defaults: cache(), autosave: false)
        session.setNote("Mine", for: "A")
        let sending = Task { await session.submit() }
        while finish == nil { await Task.yield() }
        remote.revision += 1
        remote.draft = ReviewDraft(notes: ["B": "Theirs"])
        session.receive(remote)
        finish?.resume()
        await sending.value
        XCTAssertTrue(session.conflict)
        XCTAssertFalse(session.canSubmit)
        XCTAssertEqual(session.draft.notes["A"], "Mine")
    }

    func testSingleImageReviewAlwaysKeepsAVisibleImage() {
        var only = review()
        only.options = [only.options[0]]
        let service = ReviewService(load: { only }, save: { _, _ in only }, respond: { _, _ in only }, cancel: { _ in only })
        let session = ReviewSession(threadId: "thread", review: only, service: service, defaults: cache(), autosave: false)
        session.show(0, slot: 1)
        session.browse(1)
        session.mode = .single
        XCTAssertEqual(session.visibleIndices, [0])
    }

    func testClosingSessionsSaveCannotEraseAReopenedWindowsNewerCache() async {
        var server = review()
        var finish: CheckedContinuation<Void, Never>?
        let defaults = cache()
        let service = ReviewService(load: { server }, save: { _, draft in
            await withCheckedContinuation { finish = $0 }
            server.revision += 1
            server.draft = draft
            return server
        }, respond: { _, _ in server }, cancel: { _ in server })
        let closing = ReviewSession(threadId: "thread", review: server, service: service, defaults: defaults, autosave: false)
        closing.setNote("First window", for: "A")
        let saving = Task { await closing.saveNow() }
        while finish == nil { await Task.yield() }
        let reopened = ReviewSession(threadId: "thread", review: server, service: service, defaults: defaults, autosave: false)
        reopened.setNote("Second window", for: "A")
        finish?.resume()
        await saving.value
        let recovered = ReviewSession(threadId: "thread", review: server, service: service, defaults: defaults, autosave: false)
        XCTAssertEqual(recovered.draft.notes["A"], "Second window")
    }
}
