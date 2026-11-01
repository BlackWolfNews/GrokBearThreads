import Foundation

/// The inbox's headings, top to bottom, as on the Mac sidebar
/// (app InboxSection).
public enum PhoneSection: String, Sendable, CaseIterable {
    case inbox, running, waiting, hibernating, archived

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .running: "Running"
        case .waiting: "Waiting"
        case .hibernating: "Hibernating"
        case .archived: "Archived"
        }
    }

    public var icon: String {
        switch self {
        case .inbox: "tray"
        case .running: "bolt"
        case .waiting: "clock"
        case .hibernating: "moon.zzz"
        case .archived: "archivebox"
        }
    }

    /// The backend list a put-away section's rows come from. The others'
    /// come from the inbox list, sorted on the phone.
    public var view: ThreadsView? {
        switch self {
        case .hibernating: .hibernating
        case .archived: .den
        default: nil
        }
    }
}

/// Which headings are folded, as the Mac's sidebar folds them. Everything
/// but Inbox starts folded (Mike asked 30 Oct), so the inbox is what you
/// see first. A folded Hibernating or Archived isn't loaded at all: its
/// heading shows phone:counts' number, and its threads are fetched once
/// it's opened, or while a search is on, since search looks in them too.
public struct SectionFolds: Sendable, Equatable {
    public static let initial: Set<PhoneSection> = [.running, .waiting, .hibernating, .archived]

    public private(set) var folded: Set<PhoneSection>

    public init(folded: Set<PhoneSection> = SectionFolds.initial) {
        self.folded = folded.subtracting([.inbox])
    }

    /// From what was saved: the folded sections' names. Nil (never saved)
    /// is the initial folds; names this build doesn't know are dropped.
    public init(saved: [String]?) {
        self.init(folded: saved.map { Set($0.compactMap(PhoneSection.init(rawValue:))) } ?? Self.initial)
    }

    public var saved: [String] { folded.map(\.rawValue).sorted() }

    /// Inbox never folds.
    public func isFolded(_ section: PhoneSection) -> Bool { section != .inbox && folded.contains(section) }

    public mutating func toggle(_ section: PhoneSection) {
        guard section != .inbox else { return }
        if folded.contains(section) { folded.remove(section) } else { folded.insert(section) }
    }

    /// The backend lists to keep a subscription to.
    public func views(searching: Bool) -> Set<ThreadsView> {
        var views: Set<ThreadsView> = [.inbox]
        for section in PhoneSection.allCases {
            if let view = section.view, searching || !isFolded(section) { views.insert(view) }
        }
        return views
    }
}

/// The inbox's sections, as on the Mac sidebar (app ThreadSections): Inbox
/// first, ordered by how much a thread wants Mike, then Running, since
/// there's nothing to do with those until they finish, then Waiting:
/// threads that have booked themselves a message for later and have
/// nothing for him until then. Hibernating and Archived are lists of their
/// own from the menu, as the backend sends them separately.
public struct InboxSections: Sendable, Equatable {
    public var inbox: [PhoneThread] = []
    public var running: [PhoneThread] = []
    /// Soonest to wake first.
    public var waiting: [PhoneThread] = []

    public init(inbox: [PhoneThread] = [], running: [PhoneThread] = [], waiting: [PhoneThread] = []) {
        self.inbox = inbox
        self.running = running
        self.waiting = waiting
    }

    /// The same rules as the Mac's ThreadSections.build, so the phone and
    /// the sidebar agree on what's in the inbox; change both together.
    /// Running: a turn is underway, or background work is still going.
    /// Waiting: idle with a schedule due to message it (`wakes`), and
    /// nothing for Mike: no question, no design review, no unread reply
    /// that didn't say "nothing", no open asks, not waiting for a login
    /// with room. Inbox: everything else.
    public static func build(_ threads: some Sequence<PhoneThread>, now: Date, wakes: [String: PhoneSchedule] = [:]) -> InboxSections {
        var sections = InboxSections()
        for thread in threads where thread.archivedAt == nil && !isSnoozed(thread, now: now) {
            // A question or approval goes in the inbox even while background
            // work runs: the thread is stuck until he answers. So does a
            // turn that ended asking him for something.
            if thread.reviewWaiting || needsAnswer(thread) || thread.waitingOnMike || (thread.needsYou && thread.working == nil) {
                sections.inbox.append(thread)
            } else if thread.isBusy || thread.working != nil {
                sections.running.append(thread)
            } else if thread.status == .idle, thread.needs != "you", thread.waitingForRoom == nil, wakes[thread.threadId] != nil {
                sections.waiting.append(thread)
            } else {
                sections.inbox.append(thread)
            }
        }
        sections.inbox.sort {
            let (a, b) = (urgency($0), urgency($1))
            return a != b ? a < b : newestFirst($0, $1)
        }
        sections.running.sort(by: newestFirst)
        sections.waiting.sort {
            let (a, b) = (wakes[$0.threadId]?.nextRunAt ?? .distantFuture, wakes[$1.threadId]?.nextRunAt ?? .distantFuture)
            return a != b ? a < b : newestFirst($0, $1)
        }
        return sections
    }

    /// For each thread a schedule will message by itself, the one due
    /// soonest, as the Mac's ThreadSections.wakes. Paused and finished
    /// ones don't count, nor ones that start a new thread.
    public static func wakes(_ schedules: some Sequence<PhoneSchedule>) -> [String: PhoneSchedule] {
        var soonest: [String: PhoneSchedule] = [:]
        for schedule in schedules where schedule.isActive {
            guard let threadId = schedule.threadId, let next = schedule.nextRunAt else { continue }
            if let current = soonest[threadId]?.nextRunAt, current <= next { continue }
            soonest[threadId] = schedule
        }
        return soonest
    }

    /// Lowest first. 0: stuck on his answer. 1: finished unread with a
    /// failure. 2: finished unread. 3: read but failed or stopped. 4: done.
    public static func urgency(_ thread: PhoneThread) -> Int {
        let broken = thread.status == .error || thread.status == .stopped
        if thread.reviewWaiting || needsAnswer(thread) { return 0 }
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

    public var isEmpty: Bool { inbox.isEmpty && running.isEmpty && waiting.isEmpty }
}

/// The search at the top of the inbox, as the Mac sidebar's
/// (ThreadSections.matching): every thread, the put-away ones too, each
/// section cut down to the matches in its usual order.
public struct ThreadSearch: Sendable, Equatable {
    public var inbox: [PhoneThread] = []
    public var running: [PhoneThread] = []
    public var waiting: [PhoneThread] = []
    public var hibernating: [PhoneThread] = []
    public var archived: [PhoneThread] = []

    /// `olderArchived` is what phone:search found past the den's newest 100:
    /// matched by Convex on whole words, so kept as it comes, after the
    /// archived threads the phone has.
    public init(_ query: String, sections: InboxSections, hibernating: [PhoneThread], archived: [PhoneThread],
                olderArchived: [PhoneThread] = []) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A thread can sit in two lists for a moment while the runner moves
        // it (snoozed but not yet out of the inbox view): show it once.
        var seen = Set<String>()
        let keep: ([PhoneThread]) -> [PhoneThread] = { threads in
            threads.filter { Self.matches($0, query) && seen.insert($0.threadId).inserted }
        }
        inbox = keep(sections.inbox)
        running = keep(sections.running)
        waiting = keep(sections.waiting)
        self.hibernating = keep(hibernating)
        self.archived = keep(archived) + olderArchived.filter { seen.insert($0.threadId).inserted }
    }

    /// Part of the title or the last reply, as on the Mac, or the project
    /// or folder, which on the phone's narrow rows is often all you can
    /// remember a thread by.
    public static func matches(_ thread: PhoneThread, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return [thread.title, thread.preview, thread.placeText].contains { $0.range(of: query, options: options) != nil }
    }

    public var isEmpty: Bool { inbox.isEmpty && running.isEmpty && waiting.isEmpty && hibernating.isEmpty && archived.isEmpty }
}

/// What a row says at its right: the status while it means something, else
/// the time since its last activity.
public enum RowStatus {
    /// What the status is, so the row can colour it as the Mac sidebar does.
    public enum Kind: Sendable, Equatable { case needsYou, working, failed, stopped, time }

    public static func kind(_ thread: PhoneThread) -> Kind {
        if thread.reviewWaiting || thread.pendingApproval != nil || thread.status == .waiting { return .needsYou }
        switch thread.status {
        case .running, .starting: return .working
        case .error: return .failed
        case .stopped: return .stopped
        default: return .time
        }
    }

    /// The words, as the Mac says them: "Needs you" whether it's a question
    /// or a permission (the thread says which), "Working", "Failed".
    public static func text(_ thread: PhoneThread, now: Date) -> String {
        switch kind(thread) {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .time: thread.woke != nil ? "Woke up" : RelativeTime.short(thread.lastActivityAt, now: now)
        }
    }

    /// How long a running turn has been going, where the time would be:
    /// "53s", "4m", "1h 2m". The runner sets lastActivityAt when a turn
    /// starts, so for a running thread it's the turn's start (the Mac's
    /// ThreadRowLook.workingLabel).
    public static func workingLabel(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
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

    /// "10:42" today, "Mon 10:42" otherwise: for "Mac offline since", and
    /// when a waiting thread's schedule messages it, as the Mac's
    /// RelativeTime.until.
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
