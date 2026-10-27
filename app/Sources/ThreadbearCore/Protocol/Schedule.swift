import Foundation

/// A message the runner sends at a set time, once (`at`) or over and over
/// (`cron`), to a thread or to a new thread each time (docs/protocol.md,
/// "Schedules"). Decoded as forgivingly as the other models.
public struct Schedule: Sendable, Hashable, Decodable, Identifiable {
    public struct LastRun: Sendable, Hashable, Decodable {
        public enum Outcome: String, Sendable, Hashable, Decodable {
            case sent, skipped, failed

            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Outcome(rawValue: raw) ?? .sent
            }
        }

        public var at: Date?
        public var outcome: Outcome
        /// The thread it sent to or started.
        public var threadId: String?
        /// Why it was skipped or failed.
        public var note: String?

        public init(at: Date? = nil, outcome: Outcome, threadId: String? = nil, note: String? = nil) {
            self.at = at
            self.outcome = outcome
            self.threadId = threadId
            self.note = note
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = (try? c.decodeIfPresent(String.self, forKey: .at)).flatMap(ISO8601.parse)
            outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .sent
            threadId = try? c.decodeIfPresent(String.self, forKey: .threadId)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }

        enum CodingKeys: String, CodingKey { case at, outcome, threadId, note }
    }

    public var id: String
    public var title: String
    public var text: String
    /// A one-off: when it runs.
    public var at: Date?
    /// Or repeating: a five-field cron or @daily and friends.
    public var cron: String?
    public var timezone: String?
    /// The runner's words for `at` or `cron`: "Weekdays at 9:00".
    public var whenText: String
    /// Sends to this thread; nil starts a new thread each time.
    public var threadId: String?
    /// New-thread settings.
    public var cwd: String?
    public var accountId: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var paused: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// The thread whose agent made it; nil for a person.
    public var createdBy: String?
    public var nextRunAt: Date?
    public var finishedAt: Date?
    public var runs: Int
    public var lastRun: LastRun?

    public init(
        id: String, title: String, text: String = "", at: Date? = nil, cron: String? = nil, timezone: String? = nil,
        whenText: String = "", threadId: String? = nil, cwd: String? = nil, accountId: String? = nil,
        model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, paused: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(), createdBy: String? = nil, nextRunAt: Date? = nil,
        finishedAt: Date? = nil, runs: Int = 0, lastRun: LastRun? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.at = at
        self.cron = cron
        self.timezone = timezone
        self.whenText = whenText
        self.threadId = threadId
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.nextRunAt = nextRunAt
        self.finishedAt = finishedAt
        self.runs = runs
        self.lastRun = lastRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        func date(_ key: CodingKeys) -> Date? { string(key).flatMap(ISO8601.parse) }
        id = try c.decode(String.self, forKey: .id)
        text = string(.text) ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = string(.title).flatMap { $0.isEmpty ? nil : $0 } ?? firstLine
        at = date(.at)
        cron = string(.cron)
        timezone = string(.timezone)
        whenText = string(.whenText) ?? cron ?? ""
        threadId = string(.threadId)
        cwd = string(.cwd)
        accountId = string(.accountId)
        model = string(.model)
        effort = string(.effort)
        permissionMode = try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        createdAt = date(.createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = date(.updatedAt) ?? createdAt
        createdBy = string(.createdBy)
        nextRunAt = date(.nextRunAt)
        finishedAt = date(.finishedAt)
        runs = c.lenientInt(forKey: .runs) ?? 0
        lastRun = try? c.decodeIfPresent(LastRun.self, forKey: .lastRun)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, text, at, cron, timezone, whenText, threadId, cwd, accountId, model, effort, permissionMode
        case paused, createdAt, updatedAt, createdBy, nextRunAt, finishedAt, runs, lastRun
    }

    public var isOneOff: Bool { cron == nil }
    /// A one-off that has run.
    public var isFinished: Bool { finishedAt != nil }
    /// Still going to run by itself.
    public var isActive: Bool { !paused && !isFinished }

    /// Sends to `threadId`, or was made by it (what `schedules.list` with a
    /// `threadId` returns).
    public func belongs(to threadId: String) -> Bool {
        self.threadId == threadId || createdBy == threadId
    }
}

/// What `schedules.preview` gives back: the runner's words for the time and
/// the next few times it would run.
public struct SchedulePreview: Sendable, Hashable, Decodable {
    public var whenText: String
    public var runs: [Date]

    public init(whenText: String, runs: [Date]) {
        self.whenText = whenText
        self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whenText = (try? c.decodeIfPresent(String.self, forKey: .whenText)) ?? ""
        runs = c.lossyArray(String.self, forKey: .runs).compactMap(ISO8601.parse)
    }

    enum CodingKeys: String, CodingKey { case whenText, runs }
}
