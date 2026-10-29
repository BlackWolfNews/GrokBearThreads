import Foundation

/// One line of the activity log (docs/guide.md, "Activity log"): something
/// done in the app, so an agent working on Threadbear can see how it's
/// really used (`tb activity`). Only what was pressed, opened or chosen,
/// never what's typed or the words of a message or a file. The app side is
/// ActivityRecorder.
public struct ActivityEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A mouse button pressed in one of the app's windows.
        case click
        /// A menu item chosen, from the menu bar, a right-click menu or a
        /// pop-up, by the mouse or by its key.
        case menu
        /// A shortcut that isn't a menu item's: ⌘ or ⌃ with a key, or Escape.
        case key
        /// A tooltip came up: the pointer rested on something long enough
        /// to ask what it is.
        case hover
        /// The window went somewhere else: a thread, a sub-agent, a project,
        /// a page or another sidebar view.
        case view
        /// The panels showing changed: one opened, closed or brought forward.
        case panels
        /// A message sent, a new thread started or a message edited.
        case send
        /// A permission prompt or a question answered.
        case approval
        /// Another of the app's windows came to the front (Settings, a
        /// panel's own window).
        case window
        /// The app came to the front or went behind another app.
        case app
        case launch, quit
    }

    public var at: Date
    public var kind: Kind
    /// What was clicked, chosen, pressed or hovered: a control's tooltip,
    /// a menu item ("Thread › Archive") or a key ("⌘N").
    public var target: String?
    /// The key that chose a menu item ("⌘E").
    public var key: String?
    /// "right", "middle" or "button 4"; nothing for a left click.
    public var button: String?
    /// 2 for a double click, and so on.
    public var clicks: Int?
    /// Held down with a click ("⌘", "⌥⇧").
    public var modifiers: String?
    /// For a click no tooltip names, the AppKit view under the pointer
    /// ("ComposerTextView").
    public var view: String?
    /// "main", "settings", "popover" or the window's title.
    public var window: String?
    /// The dock panel it happened in ("threadbear.threads", a patch panel).
    public var panel: String?
    /// The thread open at the time, or the one acted on.
    public var thread: String?
    /// view: the sidebar's view (inbox, scheduled, projects, librarian).
    public var mode: String?
    public var project: String?
    public var subagent: String?
    /// view: a page in place of a thread (projects, librarian, scheduled).
    public var page: String?
    /// panels: what's showing, the front panel of each group and any in
    /// windows of their own.
    public var showing: [String]?
    /// send: a new thread, not yet with an id.
    public var new: Bool?
    /// send: an edit of an earlier message.
    public var edit: Bool?
    public var images: Int?
    /// send: answers picked on the thread's card.
    public var answers: Int?
    /// approval: allow, allowAlways or deny.
    public var decision: String?
    /// app: active or inactive.
    public var state: String?
    /// launch: the app's version and the commit it was built from.
    public var version: String?
    public var build: String?

    public init(kind: Kind, at: Date = Date()) {
        self.kind = kind
        self.at = at
    }

    /// Local time with its offset, so a line read straight from the file
    /// says when it was on Mike's clock.
    static let dateStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: .current)

    /// The event as one line of JSON, without the newline.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateStyle))
        }
        return try encoder.encode(self)
    }

    public static func parse(_ line: Data) throws -> ActivityEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try dateStyle.parse(text)
        }
        return try decoder.decode(ActivityEvent.self, from: line)
    }

    /// A tooltip or menu title as a target: its first line (a thread row's
    /// tip has the folder under the title), and not a paragraph.
    public static func label(_ text: String, limit: Int = 120) -> String? {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

/// Where the log lives and how long it's kept: a file a day in the data
/// folder's `activity/`, deleted after 30 days.
public enum ActivityFiles {
    public static let keepDays = 30
    /// A day's file stops growing here, so something stuck (a key held
    /// down, a loop) can't fill the disk. A busy day is well under 1 MB.
    public static let maxDayBytes: UInt64 = 20 * 1024 * 1024

    public static func folder(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent("activity", isDirectory: true)
    }

    /// "2026-10-29.jsonl", by the local date.
    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day files from before the last `keepDays` days, to delete.
    /// Anything not named like a day file is left alone.
    public static func expired(_ names: [String], now: Date, keepDays: Int = keepDays, calendar: Calendar = .current) -> [String] {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) else { return [] }
        let oldest = fileName(for: cutoff, calendar: calendar)
        return names.filter { name in
            guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil else { return false }
            // Zero-padded dates sort as text.
            return name < oldest
        }
    }
}

/// Which key presses go in the log. Only shortcuts: a key with ⌘ or ⌃
/// held, and Escape. Anything else could be typing, and typing is never
/// recorded, not even which keys.
public enum ActivityKeys {
    /// The shortcut's name as a menu shows it ("⌘N", "⌥⌘P", "⌘↩"), or nil
    /// when it isn't one to record. `characters` is the event's
    /// charactersIgnoringModifiers.
    public static func shortcut(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, shift: Bool) -> String? {
        let name = keyName(keyCode: keyCode, characters: characters)
        guard command || control else { return keyCode == 53 ? name : nil }
        return modifiers(command: command, control: control, option: option, shift: shift) + name
    }

    /// In the order macOS menus show them.
    public static func modifiers(command: Bool, control: Bool, option: Bool, shift: Bool) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 36: return "↩"
        case 76: return "⌤"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 117: return "⌦"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "key \(keyCode)" : text.uppercased()
        }
    }
}
