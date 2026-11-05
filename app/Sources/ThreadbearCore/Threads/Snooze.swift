import Foundation

public struct SnoozePreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var date: Date

    /// Its icon in a menu.
    public var symbol: String {
        switch id {
        case "evening": return "sunset"
        case "tomorrow": return "sunrise"
        case "monday": return "briefcase"
        default: return "clock"
        }
    }

    public init(id: String, title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }
}

/// The snooze menu: 1 hour, this evening 6 pm, tomorrow 9 am, next Monday
/// 9 am. "Pick a time" is a separate item in the UI, and so is
/// `untilRestartTitle`, shown only while a runner restart is waiting.
public enum Snooze {
    /// Hibernate until the runner next starts (`snoozedUntil: "restart"`).
    public static let untilRestartTitle = "Until the runner restarts"

    public static func presets(now: Date, calendar: Calendar = .current) -> [SnoozePreset] {
        var presets: [SnoozePreset] = [
            SnoozePreset(id: "hour", title: "1 hour", date: now.addingTimeInterval(3600))
        ]
        let startOfToday = calendar.startOfDay(for: now)
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: startOfToday),
           evening.timeIntervalSince(now) > 3600 {
            // Hidden within the hour before 6 pm, where it would duplicate "1 hour".
            presets.append(SnoozePreset(id: "evening", title: "This evening, 6 pm", date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            presets.append(SnoozePreset(id: "tomorrow", title: "Tomorrow, 9 am", date: nine))
        }
        if let monday = nextMonday(after: now, calendar: calendar),
           let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: monday) {
            presets.append(SnoozePreset(id: "monday", title: "Next Monday, 9 am", date: nine))
        }
        return presets
    }

    /// The date for a preset, worked out when it's chosen rather than when
    /// the menu was built (a menu can sit open, or unrebuilt, for hours).
    /// "This evening" chosen too late to make sense falls back to an hour.
    public static func date(for presetId: String, now: Date, calendar: Calendar = .current) -> Date {
        presets(now: now, calendar: calendar).first { $0.id == presetId }?.date ?? now.addingTimeInterval(3600)
    }

    /// The next Monday strictly after today.
    static func nextMonday(after now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            if calendar.component(.weekday, from: day) == 2 { return day }
        }
        return nil
    }
}

/// How a thread hibernated in Mike's words says when it wakes. A topic
/// alone has no time: its snoozedUntil is a date the runner never reaches.
public enum WakeWords {
    public static let menuTitle = "Wake when…"
    /// The text box's examples.
    public static let placeholder = "at the weekend, in a few weeks, next time I talk about woodworking"

    /// The time it wakes by, if it has one.
    public static func time(_ thread: ThreadSummary) -> Date? {
        guard let until = thread.snoozedUntil, !thread.snoozedUntilRestart, until < farOff else { return nil }
        return until
    }

    /// What a Hibernating row shows where its time would be, and the tooltip
    /// with the rest; nil for one hibernated the ordinary way.
    public static func row(_ thread: ThreadSummary, now: Date) -> (text: String, tip: String)? {
        if let names = waitingNames(thread) {
            var tip = "Back when \(whatFor(thread))"
            if let time = time(thread) { tip += ", or \(RelativeTime.until(time, now: now)) at the latest" }
            return ("Waiting on \(names)", tip + ".")
        }
        guard let wake = thread.wakeWhen else { return nil }
        if wake.pending { return ("Thinking…", "Working out when from \"\(wake.said)\"") }
        guard let topic = wake.topic else { return nil }
        var tip = "Back when you next talk about \(topic)"
        if let time = time(thread) { tip += ", or \(RelativeTime.until(time, now: now)) at the latest" }
        return (topic, tip + ". You said \"\(wake.said)\".")
    }

    /// The thread's status line ("Hibernating until you talk about woodworking").
    public static func status(_ thread: ThreadSummary, now: Date) -> String? {
        if waitingNames(thread) != nil {
            let base = "Hibernating until \(whatFor(thread))"
            if let time = time(thread) { return base + ", or \(RelativeTime.until(time, now: now))" }
            return base
        }
        guard let wake = thread.wakeWhen else { return nil }
        if wake.pending { return "Hibernating, working out until when" }
        guard let topic = wake.topic else { return nil }
        if let time = time(thread) { return "Hibernating until you talk about \(topic), or \(RelativeTime.until(time, now: now))" }
        return "Hibernating until you talk about \(topic)"
    }

    /// The threads it still waits on (end_turn's waitFor).
    static func stillGoing(_ thread: ThreadSummary) -> [WaitingOn] {
        (thread.waitingOn ?? []).filter { !$0.done }
    }

    /// What it's still waiting for: "\"Convex I/O\" finishes", or with a
    /// condition, "\"Convex I/O\" reports the saving".
    static func whatFor(_ thread: ThreadSummary) -> String {
        let left = stillGoing(thread)
        if left.allSatisfy({ $0.until == nil }) {
            let names = left.map { "\"\($0.title)\"" }.joined(separator: left.count == 2 ? " and " : ", ")
            return names + (left.count == 1 ? " finishes" : " finish")
        }
        return left.map { "\"\($0.title)\" " + ($0.until ?? "finishes") }.joined(separator: "; ")
    }

    /// "Convex I/O", or "Convex I/O and 1 more", for the row and status line.
    static func waitingNames(_ thread: ThreadSummary) -> String? {
        let left = stillGoing(thread)
        guard let first = left.first else { return nil }
        return left.count == 1 ? "\"\(first.title)\"" : "\"\(first.title)\" and \(left.count - 1) more"
    }

    // The runner's 9999-12-31 is beyond this; any real time is well before.
    static let farOff = Date(timeIntervalSince1970: 200 * 365 * 86_400)
}
