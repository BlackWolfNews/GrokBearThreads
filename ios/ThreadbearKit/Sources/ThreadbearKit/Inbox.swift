import Foundation

/// The inbox's two sections, as on the Mac sidebar (app ThreadSections):
/// Inbox first, ordered by how much a thread wants Mike, then Running at
/// the bottom, since there's nothing to do with those until they finish.
public struct InboxSections: Sendable, Equatable {
    public var inbox: [PhoneThread] = []
    public var running: [PhoneThread] = []

    public init(inbox: [PhoneThread] = [], running: [PhoneThread] = []) {
        self.inbox = inbox
        self.running = running
    }

    public static func build(_ threads: some Sequence<PhoneThread>, now: Date) -> InboxSections {
        var sections = InboxSections()
        for thread in threads where thread.archivedAt == nil && !isSnoozed(thread, now: now) {
            // A question or approval goes in the inbox even while background
            // work runs: the thread is stuck until he answers.
            if needsAnswer(thread) || (thread.needsYou && thread.working == nil) {
                sections.inbox.append(thread)
            } else if thread.isBusy || thread.working != nil {
                sections.running.append(thread)
            } else {
                sections.inbox.append(thread)
            }
        }
        sections.inbox.sort {
            let (a, b) = (urgency($0), urgency($1))
            return a != b ? a < b : newestFirst($0, $1)
        }
        sections.running.sort(by: newestFirst)
        return sections
    }

    /// Lowest first. 0: stuck on his answer. 1: finished unread with a
    /// failure. 2: finished unread. 3: read but failed or stopped. 4: done.
    public static func urgency(_ thread: PhoneThread) -> Int {
        let broken = thread.status == .error || thread.status == .stopped
        if needsAnswer(thread) { return 0 }
        if thread.needsYou || thread.unread { return broken ? 1 : 2 }
        return broken ? 3 : 4
    }

    public static func needsAnswer(_ thread: PhoneThread) -> Bool {
        thread.pendingApproval != nil || thread.status == .waiting
    }

    static func isSnoozed(_ thread: PhoneThread, now: Date) -> Bool {
        if thread.snoozedUntilRestart == true { return true }
        guard let until = thread.snoozedUntil else { return false }
        return until > now
    }

    static func newestFirst(_ a: PhoneThread, _ b: PhoneThread) -> Bool {
        a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.threadId < b.threadId
    }

    /// The badge: threads waiting on an answer or not read yet.
    public var needsYouCount: Int {
        inbox.filter { Self.urgency($0) <= 2 }.count
    }

    public var isEmpty: Bool { inbox.isEmpty && running.isEmpty }
}

/// What a row says at its right: the status while it means something, else
/// the time since its last activity.
public enum RowStatus {
    public static func text(_ thread: PhoneThread, now: Date) -> String {
        if case .question = thread.pendingApproval { return "Asking" }
        if thread.pendingApproval != nil || thread.status == .waiting { return "Needs OK" }
        switch thread.status {
        case .running, .starting: return "Working"
        case .error: return "Failed"
        default: return RelativeTime.short(thread.lastActivityAt, now: now)
        }
    }
}

/// Short relative times, as on the Mac sidebar: "now", "5m", "3h", "Mon",
/// "12 Oct".
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

    /// "10:42" today, "Mon 10:42" otherwise: for "Mac offline since".
    public static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(calendar: calendar).hour().minute())
        }
        return date.formatted(Date.FormatStyle(calendar: calendar).weekday(.abbreviated).hour().minute())
    }
}

/// The preview is the start of the last assistant text, which is markdown.
/// Rows show it as plain words. Same rules as the Mac's PreviewText.
public enum PreviewText {
    public static func plain(_ text: String) -> String {
        var line = text
        line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(^|\s)(#{1,6}|>)\s+"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            line = line.replacingOccurrences(of: marker, with: "")
        }
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// The Hibernate menu, the Mac's snooze presets: 1 hour, this evening 6 pm,
/// tomorrow 9 am, next Monday 9 am.
public enum Hibernate {
    public struct Preset: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var date: Date
    }

    public static func presets(now: Date, calendar: Calendar = .current) -> [Preset] {
        var presets = [Preset(id: "hour", title: "1 hour", date: now.addingTimeInterval(3600))]
        let today = calendar.startOfDay(for: now)
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today),
           evening.timeIntervalSince(now) > 3600 {
            presets.append(Preset(id: "evening", title: "This evening, 6 pm", date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            presets.append(Preset(id: "tomorrow", title: "Tomorrow, 9 am", date: nine))
        }
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  calendar.component(.weekday, from: day) == 2,
                  let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
            presets.append(Preset(id: "monday", title: "Next Monday, 9 am", date: nine))
            break
        }
        return presets
    }
}
