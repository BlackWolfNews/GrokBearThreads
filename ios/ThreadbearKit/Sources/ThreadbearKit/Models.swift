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

    public init(
        threadId: String, runnerId: String = "m5", title: String, cwd: String = "~/dev/me/misc",
        accountId: String = "claude-3", provider: String = "claude", model: String? = nil,
        status: ThreadStatus = .idle, needsYou: Bool = false, unread: Bool = false, preview: String = "",
        lastActivityAt: Date, snoozedUntil: Date? = nil, snoozedUntilRestart: Bool? = nil, archivedAt: Date? = nil,
        costUsd: Double? = nil, projects: [ProjectRef]? = nil, working: String? = nil,
        pendingApproval: PendingApproval? = nil, earliestSeq: Double? = nil
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
        self._archivedAt = OptionalFlexibleDate(wrappedValue: archivedAt)
        self.costUsd = costUsd
        self.projects = projects
        self.working = working
        self.pendingApproval = pendingApproval
        self.earliestSeq = earliestSeq
    }

    public var isBusy: Bool { status == .running || status == .starting }

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

public struct PhoneMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: Int { seq }
    public var seq: Int
    public var role: Role
    public var text: String
    /// Where a user message came from: "phone", "schedule", "runner", or
    /// absent for the Mac.
    public var origin: String?
    @FlexibleDate public var at: Date

    public init(seq: Int, role: Role, text: String, origin: String? = nil, at: Date) {
        self.seq = seq
        self.role = role
        self.text = text
        self.origin = origin
        self._at = FlexibleDate(wrappedValue: at)
    }

    private enum Keys: String, CodingKey { case seq, role, text, origin, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // Convex numbers are float64, so seq comes back as 12.0.
        seq = Int(try c.decode(Double.self, forKey: .seq))
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        _at = try c.decode(FlexibleDate.self, forKey: .at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Double(seq), forKey: .seq)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encode(_at, forKey: .at)
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
