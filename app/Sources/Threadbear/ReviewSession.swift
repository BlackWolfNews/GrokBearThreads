import Foundation
import Observation
import ThreadbearCore

/// The window works against these operations so reconnecting uses the new
/// client, and draft races can be tested without a window or a real runner.
@MainActor
struct ReviewService {
    var load: () async throws -> DesignReview
    var save: (Int, ReviewDraft) async throws -> DesignReview
    var respond: (Int, ReviewDraft) async throws -> DesignReview
    var cancel: (Int) async throws -> DesignReview
}

@MainActor
@Observable
final class ReviewSession {
    let threadId: String
    private(set) var review: DesignReview
    private(set) var draft: ReviewDraft
    private(set) var dirty = false
    private(set) var saving = false
    private(set) var submitting = false
    private(set) var conflict = false
    var error: String?
    var mode: ReviewMode
    var actualSize = false
    var left = 0
    var right = 1

    @ObservationIgnored private let service: ReviewService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheKey: String
    @ObservationIgnored private let autosave: Bool
    @ObservationIgnored private let cacheOwner = UUID().uuidString
    @ObservationIgnored private var timer: Task<Void, Never>?

    private struct CachedDraft: Codable {
        var revision: Int
        var draft: ReviewDraft
        var owner: String?
        var conflict: Bool?
    }

    init(threadId: String, review: DesignReview, service: ReviewService, defaults: UserDefaults = .standard, autosave: Bool = true) {
        self.threadId = threadId
        self.review = review
        self.draft = review.response ?? review.draft
        self.service = service
        self.defaults = defaults
        self.autosave = autosave
        cacheKey = "reviewDraft.\(threadId).\(review.id)"
        mode = review.options.count > 2 ? .grid : .pair
        right = min(1, max(0, review.options.count - 1))
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(CachedDraft.self, from: data), cached.draft != draft {
            draft = cached.draft
            dirty = true
            if cached.conflict == true || cached.revision != review.revision || !review.isPending {
                conflict = true
                error = "This review changed elsewhere. Your unsent notes are kept here."
            }
            cacheDraft(force: true)
        }
    }

    var canSubmit: Bool { review.isPending && !submitting && !conflict && draft.canSubmit(options: review.options) }
    var editable: Bool { review.isPending && !submitting }
    var visibleIndices: [Int] {
        switch mode {
        case .grid: return Array(review.options.indices)
        case .pair: return ([left] + (right == left ? [] : [right])).filter { review.options.indices.contains($0) }
        case .single: return review.options.indices.contains(left) ? [left] : []
        }
    }

    func setNote(_ text: String, for id: String) {
        guard editable else { return }
        var next = draft
        next.notes[id] = text
        edit(next)
    }

    func pick(_ id: String) {
        guard editable, review.options.contains(where: { $0.id == id && !$0.reference }) else { return }
        var next = draft
        next.pickedId = next.pickedId == id ? nil : id
        edit(next)
    }

    private func edit(_ next: ReviewDraft) {
        guard next != draft else { return }
        draft = next
        dirty = true
        cacheDraft(force: true)
        scheduleSave()
    }

    private func cacheDraft(force: Bool = false) {
        // A closing window may finish its save after a new window has
        // edited this review. Its old session must leave the new cache alone.
        if !force, let existing = cachedDraft(), existing.owner != cacheOwner { return }
        if let data = try? JSONEncoder().encode(CachedDraft(revision: review.revision, draft: draft, owner: cacheOwner, conflict: conflict)) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func cachedDraft() -> CachedDraft? {
        defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(CachedDraft.self, from: $0) }
    }

    private func clearCache() {
        if cachedDraft()?.owner == cacheOwner { defaults.removeObject(forKey: cacheKey) }
    }

    private func scheduleSave() {
        guard autosave, !conflict else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        guard dirty, review.isPending, !saving, !submitting, !conflict else { return }
        saving = true
        let sent = draft
        let attemptedRevision = review.revision
        do {
            let saved = try await service.save(attemptedRevision, sent)
            if saved.revision >= review.revision { review = saved }
            dirty = normalized(draft) != (review.response ?? review.draft)
            if saved.revision < review.revision && dirty {
                conflict = true
                error = "This review changed elsewhere. Your unsent notes are kept here."
            } else { error = nil }
            if dirty { cacheDraft() } else { clearCache() }
        } catch {
            self.error = "Couldn’t save the draft. Your notes are kept on this Mac. \(error.localizedDescription)"
            saving = false
            if let latest = try? await service.load() {
                receive(latest)
                if latest.revision > attemptedRevision, latest.draft != normalized(sent), latest.draft != normalized(draft) {
                    conflict = true
                    self.error = "This review changed elsewhere. Your unsent notes are kept here."
                    cacheDraft()
                }
            }
        }
        saving = false
        // A newer keystroke may have arrived while the request was in flight.
        if dirty && error == nil { scheduleSave() }
    }

    func receive(_ latest: DesignReview) {
        guard latest.id == review.id, latest.revision >= review.revision else { return }
        let advanced = latest.revision > review.revision
        review = latest
        if !dirty {
            draft = latest.response ?? latest.draft
        } else if advanced && !saving && !submitting {
            conflict = true
            error = latest.isPending
                ? "This review changed elsewhere. Your unsent notes are kept here."
                : "This review was closed elsewhere. Your unsent notes are still shown below."
            cacheDraft()
        }
    }

    func refresh() async {
        do { receive(try await service.load()) }
        catch { self.error = "Couldn’t load the review. \(error.localizedDescription)" }
    }

    func keepMyDraft() async {
        guard review.isPending else { return }
        conflict = false
        error = nil
        dirty = true
        await saveNow()
    }

    func submit() async {
        guard canSubmit else { return }
        timer?.cancel()
        submitting = true
        // A debounce save already in flight owns the current revision.
        while saving { try? await Task.sleep(for: .milliseconds(10)) }
        defer { submitting = false }
        guard review.isPending, !conflict else { return }
        let submittedRevision = review.revision
        do {
            let answered = try await service.respond(submittedRevision, draft)
            review = answered
            draft = answered.response ?? answered.draft
            dirty = false
            conflict = false
            error = nil
            clearCache()
        } catch {
            self.error = "Couldn’t send the reply. Your notes are kept here. \(error.localizedDescription)"
            if let latest = try? await service.load() {
                // An acknowledgement can be lost after the runner committed
                // the reply. Its answered snapshot is the authority.
                if latest.status == "answered", latest.response == normalized(draft) {
                    review = latest
                    dirty = false
                    clearCache()
                    self.error = nil
                } else {
                    submitting = false
                    receive(latest)
                    if latest.isPending, latest.revision > submittedRevision, normalized(draft) != latest.draft {
                        conflict = true
                        self.error = "This review changed elsewhere. Your unsent notes are kept here."
                        cacheDraft()
                    }
                }
            }
        }
    }

    func cancelReview() async {
        guard editable else { return }
        timer?.cancel()
        submitting = true
        while saving { try? await Task.sleep(for: .milliseconds(10)) }
        defer { submitting = false }
        do {
            review = try await service.cancel(review.revision)
            dirty = false
            clearCache()
            error = nil
        } catch { self.error = "Couldn’t cancel the review. \(error.localizedDescription)" }
    }

    func show(_ index: Int, slot: Int) {
        guard review.options.indices.contains(index) else { return }
        if slot == 0 {
            if right == index { right = left }
            left = index
        } else {
            if left == index { left = right }
            right = index
        }
    }

    func browse(_ direction: Int) {
        let count = review.options.count
        guard count > 0 else { return }
        if mode == .pair { show((right + direction + count) % count, slot: 1) }
        else { show((left + direction + count) % count, slot: 0) }
    }

    /// The runner trims notes and drops blanks. A saved space at the end
    /// must not keep a draft dirty and trigger another save every 500 ms.
    private func normalized(_ draft: ReviewDraft) -> ReviewDraft {
        ReviewDraft(pickedId: draft.pickedId, notes: draft.notes.compactMapValues {
            let note = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : note
        })
    }
}

enum ReviewMode: String, CaseIterable {
    case grid = "Grid", pair = "2-up", single = "Single"
}
