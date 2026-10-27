import Foundation

/// The editor's "Repeat" choices. Each preset only builds a cron string; the
/// runner works out what it means (`schedules.preview`), so the app never
/// reads cron itself beyond recognising its own presets when editing.
public struct RepeatChoice: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Identifiable {
        case hourly, daily, weekdays, weekly, monthly, custom
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .hourly: return "Every hour"
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            case .custom: return "Custom"
            }
        }
    }

    public var kind: Kind
    public var hour: Int
    public var minute: Int
    /// Cron's day of the week: 0 is Sunday, 6 Saturday.
    public var weekday: Int
    /// Day of the month, 1 to 31 (a month without it is skipped, as in cron).
    public var day: Int
    /// What's typed in the cron field for Custom.
    public var custom: String

    public init(kind: Kind = .weekdays, hour: Int = 9, minute: Int = 0, weekday: Int = 1, day: Int = 1, custom: String = "") {
        self.kind = kind
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.day = day
        self.custom = custom
    }

    /// The cron string the choice stands for. Every hour runs on the hour.
    public var cron: String {
        switch kind {
        case .hourly: return "0 * * * *"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly: return "\(minute) \(hour) * * \(weekday)"
        case .monthly: return "\(minute) \(hour) \(day) * *"
        case .custom: return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The preset a schedule's cron came from, so editing it shows the
    /// same choice; anything else (an agent's "*/15 9-17 * * *") is Custom,
    /// with the cron in the field.
    public init(cron: String) {
        self.init(custom: cron)
        let fields = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), (0...59).contains(minute) else {
            kind = .custom
            return
        }
        if fields[1] == "*", fields[2] == "*", fields[3] == "*", fields[4] == "*" {
            if minute == 0 { kind = .hourly } else { kind = .custom }
            return
        }
        guard let hour = Int(fields[1]), (0...23).contains(hour), fields[3] == "*" else {
            kind = .custom
            return
        }
        self.hour = hour
        self.minute = minute
        switch (fields[2], fields[4]) {
        case ("*", "*"): kind = .daily
        case ("*", "1-5"): kind = .weekdays
        case ("*", let dow):
            if let weekday = Int(dow), (0...7).contains(weekday) {
                kind = .weekly
                self.weekday = weekday % 7
            } else {
                kind = .custom
            }
        case (let dom, "*"):
            if let day = Int(dom), (1...31).contains(day) {
                kind = .monthly
                self.day = day
            } else {
                kind = .custom
            }
        default:
            kind = .custom
        }
    }
}

public enum ScheduleTime {
    /// "in 12m", "in 3h", "in 2 days", or "now" once it's due.
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "in \(hours)h" }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    /// "next in 3h", or "due now" for one the runner is about to send (or
    /// catching up on after the Mac slept).
    public static func next(_ date: Date, now: Date) -> String {
        let text = relative(date, now: now)
        return text == "now" ? "due now" : "next " + text
    }

    /// Where the editor's "Once" picker starts: the next whole hour at
    /// least a quarter of an hour away.
    public static func defaultOnce(now: Date, calendar: Calendar = .current) -> Date {
        let later = now.addingTimeInterval(15 * 60)
        let hour = calendar.dateInterval(of: .hour, for: later)?.start ?? later
        return hour < later ? hour.addingTimeInterval(3600) : hour
    }
}

/// The quiet line over a thread's composer when it has schedules of its own.
public enum ScheduleLine {
    public struct Line: Sendable, Hashable {
        public var text: String
        /// The schedule it's about, when there's only one (clicking opens
        /// it); nil for several (clicking opens the Scheduled view).
        public var scheduleId: String?
    }

    /// "Scheduled: Weekdays at 9:00 · next in 3h", or "2 schedules · next
    /// in 3h". Nil when nothing active sends to the thread.
    public static func line(for threadId: String, in schedules: [Schedule], now: Date) -> Line? {
        let active = schedules.filter { $0.isActive && $0.belongs(to: threadId) }
        guard !active.isEmpty else { return nil }
        let soonest = active.compactMap(\.nextRunAt).min()
        let next = soonest.map { " · " + ScheduleTime.next($0, now: now) } ?? ""
        if active.count == 1, let only = active.first {
            return Line(text: "Scheduled: \(only.whenText)\(next)", scheduleId: only.id)
        }
        return Line(text: "\(active.count) schedules\(next)", scheduleId: nil)
    }
}

/// The line a schedule's message starts with, `[Scheduled: "<title>",
/// <whenText>]` (docs/protocol.md, "Schedules"). The transcript shows it as
/// a label rather than as part of the message.
public struct ScheduledHeader: Sendable, Hashable {
    public var title: String
    public var whenText: String
    /// The message without the header line.
    public var body: String

    public init?(_ text: String) {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("[Scheduled: \""), first.hasSuffix("]") else { return nil }
        let inner = first.dropFirst("[Scheduled: \"".count).dropLast()
        // The title may hold quotes and commas; the runner's words for the
        // time never hold `", `, so the last one splits them.
        guard let split = inner.range(of: "\", ", options: .backwards) else { return nil }
        title = String(inner[..<split.lowerBound])
        whenText = String(inner[split.upperBound...])
        body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""
    }
}

/// Words for a thread a schedule started (its summary's `schedule`), for
/// the clock on its sidebar row and the chip in its header.
public enum StartedBySchedule {
    /// What the schedule is now, if it's still there: when it runs, or that
    /// it's paused. Its title as it was when it started the thread, as the
    /// schedule may since have been renamed or deleted.
    public static func tip(_ origin: ThreadSchedule, current: Schedule?) -> String {
        let named = "Started by a schedule: \(origin.title.isEmpty ? "Untitled" : origin.title)"
        guard let current else { return named + ". It has since been deleted." }
        let when = current.paused ? "paused" : current.whenText
        return when.isEmpty ? named + ". Click to edit it." : named + " (\(when)). Click to edit it."
    }
}
