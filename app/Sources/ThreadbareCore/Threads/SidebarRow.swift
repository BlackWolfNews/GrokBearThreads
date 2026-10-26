import Foundation

/// What a sidebar row shows at the right of its title line: the relative
/// time, or a word for a state worth seeing at a glance.
public enum ThreadRowStatus: Sendable, Equatable {
    /// Nothing to say: the row shows when it was last active.
    case time
    /// A turn is running (spinner and "Working" in the accent colour).
    case working
    /// Waiting on an approval or a question ("Needs you" in orange).
    case needsYou
    /// The last turn failed.
    case failed
    /// The turn was cut off when the runner restarted.
    case stopped

    public var label: String? {
        switch self {
        case .time: return nil
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// How a thread's sidebar row looks, worked out from its summary so the
/// rules are in one tested place rather than spread through the view.
public struct ThreadRowLook: Sendable, Equatable {
    public var status: ThreadRowStatus
    /// Finished and not looked at yet: a small accent dot before the title.
    /// A thread waiting on Mike says so in words instead.
    public var unread: Bool
    /// Semibold title: the thread needs Mike or is unread.
    public var emphasised: Bool
    /// The status is said in words. Under a heading that already says it
    /// ("Needs you", "Running") the row doesn't repeat it: the word took
    /// about 60 pt of the title line, so the rows that mattered most had
    /// the most cut-off titles. A waiting row shows how long it has waited
    /// in the needs-you colour instead, and a running row just its spinner.
    public var labelled: Bool

    public init(status: ThreadRowStatus, unread: Bool, emphasised: Bool, labelled: Bool = true) {
        self.status = status
        self.unread = unread
        self.emphasised = emphasised
        self.labelled = labelled
    }

    public init(_ thread: ThreadSummary, section: InboxSection? = nil) {
        switch thread.status {
        case .waiting: status = .needsYou
        case .running, .starting: status = .working
        case .error: status = .failed
        case .stopped: status = .stopped
        case .idle: status = .time
        }
        unread = thread.needsYou && status != .needsYou && status != .working
        emphasised = thread.needsYou || status == .needsYou
        switch (status, section) {
        case (.needsYou, .needsYou?), (.working, .running?): labelled = false
        default: labelled = true
        }
    }

    /// The second line when there's no preview yet. A thread that has only
    /// asked a question is waiting on Mike, not new.
    public static func emptyPreview(_ thread: ThreadSummary) -> String {
        thread.status == .waiting ? "Waiting for your answer" : "No reply yet"
    }
}

/// Short names for accounts, for the sidebar and the new-thread line.
public enum AccountName {
    /// The part of the account's email before the @, unless another account
    /// shares it (then the whole address). Ids with no account are shown as
    /// they are.
    public static func short(_ id: String, accounts: [Account]) -> String {
        let title = accounts.first(where: { $0.id == id })?.title ?? id
        guard let at = title.firstIndex(of: "@") else { return title }
        let local = String(title[..<at])
        let clashes = accounts.filter { $0.id != id && $0.title.hasPrefix(local + "@") }
        return clashes.isEmpty ? local : title
    }

    /// Whether a row names its account: only when it isn't the main one (or
    /// the first account, if there's no main). Fixed, unlike the runner's
    /// default (the last one used), so the labels don't move about.
    public static func isShown(_ accountId: String, accounts: [Account], mainId: String) -> Bool {
        guard !accountId.isEmpty else { return false }
        let main = accounts.isEmpty || accounts.contains { $0.id == mainId } ? mainId : accounts[0].id
        return accountId != main
    }
}

/// A working folder as the sidebar header and the new-thread line name it:
/// its last component ("misc" for ~/dev/me/misc).
public enum FolderName {
    public static func short(_ path: String) -> String {
        guard let last = path.split(separator: "/").last else { return path.isEmpty ? "" : "/" }
        return String(last)
    }
}

/// Up and down through the sidebar's rows from the keyboard.
public enum SidebarOrder {
    /// The id `step` rows from `current` in `ids`, stopping at either end.
    /// With nothing selected (or the selection not in the list), down goes
    /// to the first row and up to the last.
    public static func neighbour(of current: String?, in ids: [String], step: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return step >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }
}
