import AppKit
import SwiftUI
import ThreadbareCore

/// Thread ids in replies drawn as chips. The renderer marks id-shaped
/// words (`.tbThreadRef`); this says which of them name a thread, from the
/// thread list. Main thread only: it's read while drawing.
enum ThreadChips {
    nonisolated(unsafe) private static var index = ThreadRefs.Index([])
    /// Posted when the thread list gains or loses a thread, so text already
    /// on screen can draw a new thread's id as a chip.
    static let changed = Notification.Name("ThreadChips.changed")

    static func update(_ threadIds: some Sequence<String>) {
        index = ThreadRefs.Index(threadIds)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The thread `word` names, if any.
    static func resolve(_ word: String) -> String? { index.resolve(word) }

    /// The chips in `storage`: each one's range and thread id.
    static func chips(in storage: NSAttributedString) -> [(range: NSRange, threadId: String)] {
        var found: [(NSRange, String)] = []
        storage.enumerateAttribute(.tbThreadRef, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let word = value as? String, let id = resolve(word) { found.append((range, id)) }
        }
        return found
    }
}

/// What a chip's hover card says: the thread's title, then where it is
/// and what it's doing.
struct ThreadChipCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: TypeScale.label, weight: .semibold))
                .lineLimit(2)
            Text(detail)
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Click to open")
                .font(.system(size: TypeScale.small))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 180, maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The card for a thread, or nil if it's gone.
    @MainActor static func make(threadId: String) -> ThreadChipCard? {
        let app = AppModel.shared
        guard let thread = app.threads[threadId] else { return nil }
        let title = thread.title.isEmpty ? "Untitled thread" : thread.title
        let account = thread.accountId.isEmpty ? nil : AccountName.short(thread.accountId, accounts: app.accounts)
        return ThreadChipCard(title: title, detail: ThreadRefs.detail(thread, account: account, now: Date()))
    }
}
