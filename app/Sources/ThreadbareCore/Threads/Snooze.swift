import Foundation

public struct SnoozePreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var date: Date

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
