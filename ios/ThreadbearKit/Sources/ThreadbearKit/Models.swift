import Foundation

// The rows `convex/phone.ts` returns. Field names follow the runner's
// ThreadSummary (runner/src/protocol.ts) so the two read the same; the
// runner mirrors only what the phone shows (docs/convex-backend.md).

public enum ThreadStatus: String, Codable, Sendable {
    case idle, starting, running, waiting, error, stopped
    /// A status a newer runner sends that this build doesn't know.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadStatus(rawValue: raw) ?? .unknown
    }
}

public enum ApprovalOption: String, Codable, Sendable, Hashable {
    case allow, allowAlways, deny
}

public struct Question: Codable, Sendable, Hashable {
    public struct Option: Codable, Sendable, Hashable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [Option]

    public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [Option]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// What a thread is stuck on: a tool wanting permission, or the agent's
/// questions.
public enum PendingApproval: Codable, Sendable, Hashable {
    case approval(id: String, name: String, title: String, options: [ApprovalOption], inputSummary: String?)
    case question(id: String, questions: [Question])

    public var id: String {
        switch self {
        case let .approval(id, _, _, _, _), let .question(id, _): id
        }
    }

    private enum Keys: String, CodingKey { case approvalId, kind, name, title, options, inputSummary, questions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(String.self, forKey: .approvalId)
        if try c.decodeIfPresent(String.self, forKey: .kind) == "question" {
            self = .question(id: id, questions: try c.decode([Question].self, forKey: .questions))
        } else {
            // Options this build doesn't know are dropped rather than
            // failing the whole inbox.
            let raw = try c.decodeIfPresent([String].self, forKey: .options) ?? ["allow", "deny"]
            self = .approval(
                id: id,
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Permission",
                options: raw.compactMap(ApprovalOption.init(rawValue:)),
                inputSummary: try c.decodeIfPresent(String.self, forKey: .inputSummary)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .approval(id, name, title, options, inputSummary):
            try c.encode(id, forKey: .approvalId)
            try c.encode("approval", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(title, forKey: .title)
            try c.encode(options, forKey: .options)
            try c.encodeIfPresent(inputSummary, forKey: .inputSummary)
        case let .question(id, questions):
            try c.encode(id, forKey: .approvalId)
            try c.encode("question", forKey: .kind)
            try c.encode(questions, forKey: .questions)
        }
    }
}

public struct ProjectRef: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A project's icon as the Mac shows it (docs/protocol.md, "Icons"): its
/// picture, here a URL into the backend's file storage (backend API 5),
/// else an SF Symbol. Neither: the title's first letter.
public struct PhoneProjectIcon: Codable, Sendable, Hashable {
    public var symbol: String?
    public var url: URL?
    /// "mike", "agent" or "librarian": who chose it.
    public var by: String?

    public init(symbol: String? = nil, url: URL? = nil, by: String? = nil) {
        self.symbol = symbol
        self.url = url
        self.by = by
    }

    private enum Keys: String, CodingKey { case symbol, url, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        // A URL that doesn't parse is no picture, not a broken row.
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0 }.flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(symbol, forKey: .symbol)
        try c.encodeIfPresent(url?.absoluteString, forKey: .url)
        try c.encodeIfPresent(by, forKey: .by)
    }
}

/// A row of phone:projects: what a thread's ProjectRef points at, as far as
/// the rows need (the icon, the title). The rest of the runner's Project is
/// in the row too but not read yet.
public struct PhoneProject: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var runnerId: String?
    public var title: String
    public var archived: Bool?
    public var icon: PhoneProjectIcon?

    public init(id: String, runnerId: String? = nil, title: String, archived: Bool? = nil, icon: PhoneProjectIcon? = nil) {
        self.id = id
        self.runnerId = runnerId
        self.title = title
        self.archived = archived
        self.icon = icon
    }

    private enum Keys: String, CodingKey { case id, runnerId, title, archived, icon }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        runnerId = (try? c.decodeIfPresent(String.self, forKey: .runnerId)).flatMap { $0 }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)).flatMap { $0 }
        icon = (try? c.decodeIfPresent(PhoneProjectIcon.self, forKey: .icon)).flatMap { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(runnerId, forKey: .runnerId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeIfPresent(icon, forKey: .icon)
    }
}

/// "C" for "Convex docs", "7" for "7 day plan", "?" for a title with
/// neither (all emoji, or empty). The Mac's ProjectMark.letter.
public enum ProjectMark {
    public static func letter(_ title: String) -> String {
        guard let first = title.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }
}

/// When a hibernating thread came back by itself, and when it went away.
public struct Woke: Codable, Sendable, Hashable {
    @FlexibleDate public var at: Date
    @OptionalFlexibleDate public var since: Date?

    public init(at: Date, since: Date? = nil) {
        self._at = FlexibleDate(wrappedValue: at)
        self._since = OptionalFlexibleDate(wrappedValue: since)
    }
}

public struct PhoneThread: Codable, Sendable, Hashable, Identifiable {
    public var id: String { threadId }
    public var threadId: String
    public var runnerId: String
    public var title: String
    public var cwd: String
    public var accountId: String
    public var provider: String
    public var model: String?
    public var status: ThreadStatus
    public var needsYou: Bool
    public var unread: Bool
    public var preview: String
    @FlexibleDate public var lastActivityAt: Date
    @OptionalFlexibleDate public var snoozedUntil: Date?
    public var snoozedUntilRestart: Bool?
    /// Back from hibernating by itself and not opened yet: the row says
    /// "Woke up", as the Mac's does.
    public var woke: Woke?
    @OptionalFlexibleDate public var archivedAt: Date?
    public var costUsd: Double?
    public var projects: [ProjectRef]?
    /// The working line ("Running npm test"), while a turn or background
    /// work is going.
    public var working: String?
    public var pendingApproval: PendingApproval?
    /// The seq of the thread's first text message, so the phone knows
    /// whether there's anything older than what it has to load. A Convex
    /// number, so a Double on the wire.
    public var earliestSeq: Double?
    /// The open card of asks from the agent's end_turn (backend API 14):
    /// what Mike has to do, shown under the reply with its options.
    public var asks: [PhoneAsk]?
    /// Which turn the card came with (a Convex number).
    public var asksSeq: Double?
    /// A finished turn's suggested follow-ups (end_turn's `next`), for the
    /// done card.
    public var next: [String]?
    /// What the last completed turn said it needs from Mike, "you" or
    /// "nothing" (backend API 15). Absent: it said neither.
    public var needs: String?
    /// Design reviews waiting on Mike (backend API 15), a Convex number.
    public var pendingReviews: Double?
    /// Every login it could use is out of room until then (backend API 15).
    public var waitingForRoom: PhoneWaitingForRoom?

    public init(
        threadId: String, runnerId: String = "m5", title: String, cwd: String = "~/dev/me/misc",
        accountId: String = "claude-3", provider: String = "claude", model: String? = nil,
        status: ThreadStatus = .idle, needsYou: Bool = false, unread: Bool = false, preview: String = "",
        lastActivityAt: Date, snoozedUntil: Date? = nil, snoozedUntilRestart: Bool? = nil, woke: Woke? = nil, archivedAt: Date? = nil,
        costUsd: Double? = nil, projects: [ProjectRef]? = nil, working: String? = nil,
        pendingApproval: PendingApproval? = nil, earliestSeq: Double? = nil,
        asks: [PhoneAsk]? = nil, asksSeq: Double? = nil, next: [String]? = nil,
        needs: String? = nil, pendingReviews: Double? = nil, waitingForRoom: PhoneWaitingForRoom? = nil
    ) {
        self.threadId = threadId
        self.runnerId = runnerId
        self.title = title
        self.cwd = cwd
        self.accountId = accountId
        self.provider = provider
        self.model = model
        self.status = status
        self.needsYou = needsYou
        self.unread = unread
        self.preview = preview
        self._lastActivityAt = FlexibleDate(wrappedValue: lastActivityAt)
        self._snoozedUntil = OptionalFlexibleDate(wrappedValue: snoozedUntil)
        self.snoozedUntilRestart = snoozedUntilRestart
        self.woke = woke
        self._archivedAt = OptionalFlexibleDate(wrappedValue: archivedAt)
        self.costUsd = costUsd
        self.projects = projects
        self.working = working
        self.pendingApproval = pendingApproval
        self.earliestSeq = earliestSeq
        self.asks = asks
        self.asksSeq = asksSeq
        self.next = next
        self.needs = needs
        self.pendingReviews = pendingReviews
        self.waitingForRoom = waitingForRoom
    }

    public var isBusy: Bool { status == .running || status == .starting }

    /// A design review is waiting on Mike and the thread has finished
    /// working, as the Mac's ThreadSummary.reviewWaiting.
    public var reviewWaiting: Bool { (pendingReviews ?? 0) > 0 && !isBusy && working == nil }

    /// Whether there are older text messages on the Mac than `oldestSeq`,
    /// the oldest the phone has. False when the runner doesn't say.
    public func hasEarlier(than oldestSeq: Int?) -> Bool {
        guard let earliestSeq, let oldestSeq else { return false }
        return oldestSeq > Int(earliestSeq)
    }

    /// The last folder name, for a thread in no project: "misc".
    public var folderName: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? cwd
    }

    /// Line 2 of a row: the projects, comma-joined, or the folder, as on
    /// the Mac sidebar.
    public var placeText: String {
        if let projects, !projects.isEmpty { return projects.map(\.title).joined(separator: ", ") }
        return folderName
    }
}

/// When a thread waiting for a login with room can go on.
public struct PhoneWaitingForRoom: Codable, Sendable, Hashable {
    public var until: String
    public var accountId: String?

    public init(until: String, accountId: String? = nil) {
        self.until = until
        self.accountId = accountId
    }
}

/// A row of phone:schedules: a message the runner sends by itself, once or
/// on a cron. The phone reads only what the inbox's Waiting section needs.
public struct PhoneSchedule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var runnerId: String?
    public var title: String
    /// "Every weekday at 9:00", "Tomorrow at 10:00": the runner's words.
    public var whenText: String
    /// The thread it messages. Absent: it starts a new thread each time.
    public var threadId: String?
    public var paused: Bool
    @OptionalFlexibleDate public var nextRunAt: Date?
    @OptionalFlexibleDate public var finishedAt: Date?

    public init(id: String, runnerId: String? = nil, title: String = "", whenText: String = "", threadId: String? = nil,
                paused: Bool = false, nextRunAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.runnerId = runnerId
        self.title = title
        self.whenText = whenText
        self.threadId = threadId
        self.paused = paused
        self._nextRunAt = OptionalFlexibleDate(wrappedValue: nextRunAt)
        self._finishedAt = OptionalFlexibleDate(wrappedValue: finishedAt)
    }

    private enum Keys: String, CodingKey { case id, runnerId, title, whenText, threadId, paused, nextRunAt, finishedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        runnerId = (try? c.decodeIfPresent(String.self, forKey: .runnerId)).flatMap { $0 }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        whenText = (try? c.decodeIfPresent(String.self, forKey: .whenText)).flatMap { $0 } ?? ""
        threadId = (try? c.decodeIfPresent(String.self, forKey: .threadId)).flatMap { $0 }
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)).flatMap { $0 } ?? false
        _nextRunAt = try c.decode(OptionalFlexibleDate.self, forKey: .nextRunAt)
        _finishedAt = try c.decode(OptionalFlexibleDate.self, forKey: .finishedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(runnerId, forKey: .runnerId)
        try c.encode(title, forKey: .title)
        try c.encode(whenText, forKey: .whenText)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encode(paused, forKey: .paused)
        try c.encode(_nextRunAt, forKey: .nextRunAt)
        try c.encode(_finishedAt, forKey: .finishedAt)
    }

    /// Still going to run by itself, as the Mac's Schedule.isActive.
    public var isActive: Bool { !paused && finishedAt == nil }
}

public struct PhoneMessage: Codable, Sendable, Hashable, Identifiable {
    /// `tool` is one line for a tool call (backend API 2, phone:messages).
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public var id: Int { seq }
    public var seq: Int
    public var role: Role
    public var text: String
    /// Where a user message came from: "phone", "schedule", "runner", or
    /// absent for the Mac.
    public var origin: String?
    /// For a tool line: the protocol's ToolKind ("command", "read", "edit"...).
    public var toolKind: String?
    /// The turn's summary bullets from end_turn, its reply (backend API 14).
    public var summary: Bool
    @FlexibleDate public var at: Date

    public init(seq: Int, role: Role, text: String, origin: String? = nil, toolKind: String? = nil, summary: Bool = false, at: Date) {
        self.seq = seq
        self.role = role
        self.text = text
        self.origin = origin
        self.toolKind = toolKind
        self.summary = summary
        self._at = FlexibleDate(wrappedValue: at)
    }

    private enum Keys: String, CodingKey { case seq, role, text, origin, toolKind, summary, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // Convex numbers are float64, so seq comes back as 12.0.
        seq = Int(try c.decode(Double.self, forKey: .seq))
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        toolKind = try c.decodeIfPresent(String.self, forKey: .toolKind)
        summary = (try? c.decodeIfPresent(Bool.self, forKey: .summary)).flatMap { $0 } ?? false
        _at = try c.decode(FlexibleDate.self, forKey: .at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Double(seq), forKey: .seq)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(toolKind, forKey: .toolKind)
        if summary { try c.encode(true, forKey: .summary) }
        try c.encode(_at, forKey: .at)
    }
}

/// When this phone is notified that a thread needs Mike (backend API 3).
/// `away` (the default) only while he isn't at the Mac: the Mac app is
/// closed, or the keyboard and mouse have been idle a couple of minutes.
public enum NotifyMode: String, CaseIterable, Sendable, Codable {
    case away, always, off

    public var label: String {
        switch self {
        case .away: "When I'm away from the Mac"
        case .always: "Always"
        case .off: "Never"
        }
    }
}

/// phone:messages: a thread's newest messages, oldest first, and whether
/// there are older ones.
public struct MessagePage: Codable, Sendable, Hashable {
    public var messages: [PhoneMessage]
    public var hasMore: Bool
    public init(messages: [PhoneMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// A thread as shown: messages, with the tool calls between two of them
/// gathered into one run.
public enum ThreadItem: Identifiable, Hashable, Sendable {
    case message(PhoneMessage)
    case tools([PhoneMessage])
    /// A finished turn's work, folded into one "Worked for 2m 13s" line
    /// (Turns.fold).
    case worked(WorkedTurn)

    public var id: Int {
        switch self {
        case let .message(m): m.seq
        case let .tools(items): items.first?.seq ?? 0
        // Negative, so it never meets the seq of the message it folds.
        case let .worked(w): -(w.items.first?.id ?? 0) - 1
        }
    }

    public static func group(_ messages: [PhoneMessage]) -> [ThreadItem] {
        var out: [ThreadItem] = []
        for m in messages {
            if m.role == .tool {
                if case var .tools(items)? = out.last {
                    items.append(m)
                    out[out.count - 1] = .tools(items)
                } else {
                    out.append(.tools([m]))
                }
            } else {
                out.append(.message(m))
            }
        }
        return out
    }
}

public struct ThreadDetail: Codable, Sendable, Hashable {
    public var thread: PhoneThread
    public var messages: [PhoneMessage]
    public init(thread: PhoneThread, messages: [PhoneMessage]) {
        self.thread = thread
        self.messages = messages
    }
}

public struct PhoneRunner: Codable, Sendable, Hashable, Identifiable {
    public var id: String { runnerId }
    public var runnerId: String
    public var name: String
    public var version: String?
    @FlexibleDate public var lastSeenAt: Date
    public var draining: Bool?

    public init(runnerId: String, name: String, version: String? = nil, lastSeenAt: Date, draining: Bool? = nil) {
        self.runnerId = runnerId
        self.name = name
        self.version = version
        self._lastSeenAt = FlexibleDate(wrappedValue: lastSeenAt)
        self.draining = draining
    }

    /// The runner writes a heartbeat every 60 s; three missed is offline.
    public static let offlineAfter: TimeInterval = 180

    public func isOnline(at now: Date) -> Bool { now.timeIntervalSince(lastSeenAt) < Self.offlineAfter }
}

public struct PhoneIdentity: Codable, Sendable, Hashable {
    public var name: String
    @OptionalFlexibleDate public var expiresAt: Date?
    /// The backend's API version (convex/version.ts). Missing from backends
    /// deployed before there was one.
    public var apiVersion: Int?
    public init(name: String, expiresAt: Date?, apiVersion: Int? = nil) {
        self.name = name
        self._expiresAt = OptionalFlexibleDate(wrappedValue: expiresAt)
        self.apiVersion = apiVersion
    }
}

/// Whether the backend on the Mac is new enough for this build of the app.
/// The App Store app meets backends of every age (everyone's Threadbear
/// updates on its own schedule), so it says when one is too old rather than
/// failing in odd ways. docs/setup-and-updates.md section 2.4.
public enum BackendCompatibility {
    /// The lowest backend API version this app works with. Raise it only when
    /// the app starts relying on something a newer backend added.
    public static let minimumAPIVersion = 1
    /// The newest backend API this app knows. From 2 a thread's messages come
    /// from phone:messages (every message and tool line, paged in Convex);
    /// an older backend still gets phone:thread and the runner's paging.
    public static let currentAPIVersion = 17
    public static let messagePagesAPIVersion = 2
    /// From 3 each phone chooses when it's notified (phone:setNotifications).
    public static let notificationSettingAPIVersion = 3
    /// From 4 registerDevice takes the phone's relay key.
    public static let pushKeyAPIVersion = 4
    /// From 5 phone:projects rows carry each project's icon (a symbol, and
    /// a picture as a URL). Older backends answer the same query without it.
    public static let projectIconsAPIVersion = 5
    /// From 10 phone:quickAsk records a quick ask as a thread.
    public static let quickAskAPIVersion = 10
    /// From 14 thread rows carry the open card of asks and the done card's
    /// next steps, and phone:send takes answers. Older backends leave them
    /// out, and the phone shows neither card.
    public static let asksAPIVersion = 14
    /// From 15 thread rows carry needs, pendingReviews and waitingForRoom,
    /// so the inbox's sections match the Mac's. Older backends leave them
    /// out, and a thread with a schedule waits unless it needs Mike in a
    /// way the phone can see.
    public static let sectionsAPIVersion = 15
    /// From 16 phone:search finds archived threads past the den's newest
    /// 100. Older backends don't have it, and the search stops at those.
    public static let searchAPIVersion = 16
    /// From 17 phone:counts says how many threads are hibernating and
    /// archived, for the folded headings. Older backends don't have it, so
    /// those headings show no number until opened.
    public static let countsAPIVersion = 17

    /// The line to show, or nil when the backend is fine.
    public static func problem(_ identity: PhoneIdentity) -> String? {
        let version = identity.apiVersion ?? 0
        guard version < minimumAPIVersion else { return nil }
        return "Threadbear on your Mac is older than this app expects, so some things may not work. Update it on the Mac."
    }
}

public enum CommandState: String, Codable, Sendable {
    case pending, taken, done, failed
}

public struct CommandStatus: Codable, Sendable, Hashable {
    public var state: CommandState
    public var note: String?
    public var threadId: String?
    public init(state: CommandState, note: String? = nil, threadId: String? = nil) {
        self.state = state
        self.note = note
        self.threadId = threadId
    }
}

/// phone:counts (backend API 16): how many threads are hibernating and
/// archived, uncapped. Convex numbers, so Doubles on the wire.
public struct PhoneCounts: Codable, Sendable, Hashable {
    public var hibernating: Int
    public var den: Int

    public init(hibernating: Int, den: Int) {
        self.hibernating = hibernating
        self.den = den
    }

    private enum Keys: String, CodingKey { case hibernating, den }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        hibernating = Int((try? c.decodeIfPresent(Double.self, forKey: .hibernating)).flatMap { $0 } ?? 0)
        den = Int((try? c.decodeIfPresent(Double.self, forKey: .den)).flatMap { $0 } ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(hibernating, forKey: .hibernating)
        try c.encode(den, forKey: .den)
    }
}

public enum ThreadsView: String, Sendable, CaseIterable {
    case inbox, hibernating, den
}

public enum ThreadChange: Sendable, Hashable {
    case snooze(until: Date)
    case snoozeUntilRestart
    case wake
    case archive
    case unarchive
    case markSeen
    case rename(String)

    var json: JSONValue {
        switch self {
        case let .snooze(until): ["snooze": ["until": .string(ISODate.string(until))]]
        case .snoozeUntilRestart: ["snooze": ["untilRestart": true]]
        case .wake: ["wake": true]
        case .archive: ["archive": true]
        case .unarchive: ["unarchive": true]
        case .markSeen: ["markSeen": true]
        case let .rename(title): ["title": .string(title)]
        }
    }
}
