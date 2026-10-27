import Foundation

/// The inbox's sections, top to bottom.
public enum InboxSection: String, Sendable, CaseIterable {
    case needsYou, running, inbox

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .inbox: return "Inbox"
        }
    }
}

/// The sidebar's three sections.
public struct ThreadSections: Sendable, Equatable {
    public var needsYou: [ThreadSummary] = []
    public var running: [ThreadSummary] = []
    public var inbox: [ThreadSummary] = []

    public init(needsYou: [ThreadSummary] = [], running: [ThreadSummary] = [], inbox: [ThreadSummary] = []) {
        self.needsYou = needsYou
        self.running = running
        self.inbox = inbox
    }

    /// Needs you: waiting on an approval or question, or finished and unread.
    /// Running: a turn is underway, or background sub-agents or jobs are
    /// still going (an unread reply waits there with its dot until they're
    /// done: the thread isn't finished yet). Inbox: everything else. Snoozed
    /// and archived threads are left out. Each section is newest activity
    /// first.
    public static func build(_ threads: some Sequence<ThreadSummary>, now: Date) -> ThreadSections {
        var sections = ThreadSections()
        for thread in threads where !thread.isArchived && !thread.isSnoozed(at: now) {
            if thread.status == .waiting || (thread.needsYou && !thread.isWorkingInBackground) {
                sections.needsYou.append(thread)
            } else if thread.status == .running || thread.status == .starting || thread.isWorkingInBackground {
                sections.running.append(thread)
            } else {
                sections.inbox.append(thread)
            }
        }
        let newestFirst: (ThreadSummary, ThreadSummary) -> Bool = {
            $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id
        }
        sections.needsYou.sort(by: newestFirst)
        sections.running.sort(by: newestFirst)
        sections.inbox.sort(by: newestFirst)
        return sections
    }

    public var all: [ThreadSummary] { needsYou + running + inbox }

    public subscript(section: InboxSection) -> [ThreadSummary] {
        switch section {
        case .needsYou: return needsYou
        case .running: return running
        case .inbox: return inbox
        }
    }

    /// Archived threads, most recently archived first, filtered by a search
    /// that matches title or preview (case and accent insensitive).
    public static func archived(_ threads: some Sequence<ThreadSummary>, matching query: String = "") -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return threads
            .filter { $0.isArchived }
            .filter { trimmed.isEmpty || matches($0, trimmed) }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    public static func snoozed(_ threads: some Sequence<ThreadSummary>, now: Date) -> [ThreadSummary] {
        threads
            .filter { !$0.isArchived && $0.isSnoozed(at: now) }
            .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }

    public static func matches(_ thread: ThreadSummary, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return thread.title.range(of: query, options: options) != nil
            || thread.preview.range(of: query, options: options) != nil
    }
}

/// Short relative times for the sidebar: "now", "5m", "3h", "Mon", "12 Oct".
public enum RelativeTime {
    public static func short(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 6 * 86_400 {
            return date.formatted(Date.FormatStyle(calendar: calendar).weekday(.abbreviated))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(calendar: calendar).day().month(.abbreviated)
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }

    /// "in 3h", "tomorrow 9:00" style text for snoozed rows.
    public static func until(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(calendar: calendar).hour().minute())
        }
        return date.formatted(Date.FormatStyle(calendar: calendar).weekday(.abbreviated).hour().minute())
    }

    /// "1m 12s", "850 ms", "2h 4m".
    public static func duration(milliseconds: Double) -> String {
        if milliseconds < 1000 { return "\(Int(milliseconds)) ms" }
        let total = Int(milliseconds / 1000)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// A thread's model for the composer menu. The menu's aliases ("haiku")
/// read as words; a full id ("claude-haiku-5-5") is shown as it is, since
/// capitalising it gave "Claude-Haiku-5-5".
public enum ModelName {
    public static func display(_ model: String) -> String {
        model.allSatisfy(\.isLetter) ? model.capitalized : model
    }
}

/// A turn's cost for its footer. Small models cost well under a cent a
/// turn, which two decimals showed as "$0.00".
public enum CostText {
    public static func format(_ cost: Double?) -> String? {
        guard let cost, cost > 0 else { return nil }
        if cost >= 0.01 { return String(format: "$%.2f", cost) }
        if cost >= 0.001 { return String(format: "$%.3f", cost) }
        return "<$0.001"
    }
}

/// The runner's preview is the start of the last assistant text, which is
/// markdown. The sidebar shows it as plain words.
public enum PreviewText {
    public static func plain(_ text: String) -> String {
        var line = text
        // [label](url) reads as the label.
        line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Heading and quote markers wherever a line started (the preview has
        // its newlines folded into spaces, so look after any whitespace too).
        line = line.replacingOccurrences(of: #"(^|\s)(#{1,6}|>)\s+"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            line = line.replacingOccurrences(of: marker, with: "")
        }
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespaces)
    }
}
