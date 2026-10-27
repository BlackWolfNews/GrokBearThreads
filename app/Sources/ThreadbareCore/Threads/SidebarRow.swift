import Foundation

/// What a sidebar row shows at the right of its title line: the relative
/// time, or a word for a state worth seeing at a glance.
public enum ThreadRowStatus: Sendable, Equatable {
    /// Nothing to say: the row shows when it was last active.
    case time
    /// A turn is running (spinner and "Working" in the accent colour).
    case working
    /// No turn, but background sub-agents or jobs are still going (a grey
    /// spinner and what's running: "3 sub-agents"). `BackgroundWork.short`
    /// has the words; `label` is the generic one.
    case background
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
        case .background: return "In the background"
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
    /// The status is said in words. Under the Running heading a working
    /// row doesn't repeat it (the word took about 60 pt of the title line)
    /// and shows just its spinner. Waiting rows keep "Needs you": since
    /// Needs you merged into the inbox, the word is what says why a row
    /// sits at the top.
    public var labelled: Bool

    public init(status: ThreadRowStatus, unread: Bool, emphasised: Bool, labelled: Bool = true) {
        self.status = status
        self.unread = unread
        self.emphasised = emphasised
        self.labelled = labelled
    }

    public init(_ thread: ThreadSummary, section: InboxSection? = nil) {
        if thread.hasPendingReviews {
            status = .needsYou
        } else {
            switch thread.status {
            case .waiting: status = .needsYou
            case .running, .starting: status = .working
            case .error: status = .failed
            case .stopped: status = .stopped
            case .idle: status = thread.background.isEmpty ? .time : .background
            }
        }
        unread = thread.needsYou && status != .needsYou && status != .working
        emphasised = thread.needsYou || status == .needsYou
        labelled = !(status == .working && section == .running)
    }

    /// How long a running turn has been going, where the time would be:
    /// "53s", "4m", "1h 2m". The runner sets a thread's `lastActivityAt`
    /// when a turn starts (and when it ends or a message is sent), not on
    /// every event, so for a running thread it's the turn's start.
    public static func workingLabel(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    }
}

/// Snoozing or archiving a thread whose turn is underway makes the runner
/// stop that turn. From the row's hover buttons, where a stray click is
/// easy, that asks first; the menus and ⌘E are deliberate and don't.
public enum BusyThreadAction {
    public enum Action: Sendable {
        case archive, snooze
    }

    /// A turn underway, or background work the runner would stop.
    public static func needsConfirm(_ thread: ThreadSummary) -> Bool { thread.status.isBusy || !thread.background.isEmpty }

    /// The confirmation's question and its explanation.
    public static func prompt(_ action: Action, thread: ThreadSummary) -> (title: String, detail: String) {
        let verb = action == .archive ? "Archive" : "Hibernate"
        let doing = action == .archive ? "Archiving" : "Hibernating"
        if !thread.status.isBusy {
            // Only background work: sub-agents or jobs the runner stops
            // when it lets the CLI go.
            let what = BackgroundWork.short(thread.background).lowercased()
            return ("\(verb) and stop the background work?", "This thread still has \(what) in the background. \(doing) it now stops them.")
        }
        let state = thread.status == .waiting ? "is waiting for you" : "is still working"
        return ("\(verb) and stop the turn?", "This thread \(state). \(doing) it now stops its turn.")
    }
}

/// Names for accounts, for the sidebar, the composer and its menus. Built
/// from the account's email and provider rather than its title, so a Claude
/// login and a Codex login with the same address (claude-1 and codex-main
/// are both mike.cann@gmail.com) don't clash.
public enum AccountName {
    /// The bare address when the runner sends one, else the title without
    /// Codex's "Codex · " prefix (older runners), else the id.
    public static func title(_ account: Account) -> String {
        if let email = account.email, !email.isEmpty { return email }
        let prefix = "Codex · "
        if account.title.hasPrefix(prefix) { return String(account.title.dropFirst(prefix.count)) }
        return account.title.isEmpty ? account.id : account.title
    }

    /// A Claude account: the part of its email before the @, unless another
    /// Claude account shares it (then the whole address). A Codex account:
    /// "Codex" when it's the only Codex login, "Codex mike.cann" when
    /// there are several. Ids with no account are shown as they are.
    public static func short(_ id: String, accounts: [Account]) -> String {
        guard let account = accounts.first(where: { $0.id == id }) else { return id }
        let full = title(account)
        let siblings = accounts.filter { $0.id != id && $0.provider == account.provider }
        if account.provider == "codex" {
            guard !siblings.isEmpty else { return "Codex" }
            return "Codex " + localPart(full)
        }
        guard full.contains("@") else { return full }
        let local = localPart(full)
        let clashes = siblings.filter { localPart(title($0)) == local }
        return clashes.isEmpty ? local : full
    }

    /// A name for a card, where a whole address doesn't fit: the part
    /// before the @ when that's the only one, else the domain's first part
    /// ("cannstudios", "gangbusters", "convex"), which is how Mike tells
    /// his logins apart. Codex as `short`; the whole address when neither
    /// is unique.
    public static func label(_ id: String, accounts: [Account]) -> String {
        guard let account = accounts.first(where: { $0.id == id }) else { return id }
        if account.provider == "codex" { return short(id, accounts: accounts) }
        let full = title(account)
        guard let at = full.firstIndex(of: "@") else { return full }
        let siblings = accounts.filter { $0.id != id && $0.provider == account.provider }.map(title)
        let local = localPart(full)
        if !siblings.contains(where: { localPart($0) == local }) { return local }
        func domain(_ address: String) -> String {
            guard let at = address.firstIndex(of: "@") else { return address }
            return String(address[address.index(after: at)...].prefix { $0 != "." })
        }
        let own = domain(String(full[at...]))
        return own.isEmpty || siblings.contains(where: { domain($0) == own }) ? full : own
    }

    static func localPart(_ address: String) -> String {
        guard let at = address.firstIndex(of: "@") else { return address }
        return String(address[..<at])
    }
}

/// The project mark at the right of a thread's row, where its account
/// used to be named. Until projects have icons it's the project's first
/// letter or digit on a quiet tile.
public enum ProjectMark {
    /// The project the row shows: the first it joined. A thread in two
    /// projects names both in the mark's tooltip.
    public static func project(_ thread: ThreadSummary) -> ThreadProject? { thread.projects.first }

    /// "C" for "Convex docs", "7" for "7 day plan", "?" for a title with
    /// neither (all emoji, or empty).
    public static func letter(_ title: String) -> String {
        guard let first = title.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    /// The tooltip: every project the thread is in.
    public static func help(_ thread: ThreadSummary) -> String {
        thread.projects.map { $0.title.isEmpty ? "Untitled project" : $0.title }.joined(separator: ", ")
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
