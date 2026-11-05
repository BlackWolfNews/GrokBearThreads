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
    /// Or the pool that picks the login each run; never both.
    public var poolId: String?
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
    /// The runner it runs on (docs/protocol.md, "Schedules", "Runners").
    /// Nil from a runner whose schedules are its own file: then it's that one.
    public var runnerId: String?
    /// That runner's name, as `runners.list` has it.
    public var runnerName: String?
    /// That runner's SF Symbol (`RunnerInfo.icon`), for telling runners apart.
    public var runnerIcon: String?
    /// A "Run now" asked of another runner, waiting for it to hear.
    public var runRequestedAt: Date?

    public init(
        id: String, title: String, text: String = "", at: Date? = nil, cron: String? = nil, timezone: String? = nil,
        whenText: String = "", threadId: String? = nil, cwd: String? = nil, accountId: String? = nil,
        poolId: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, paused: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(), createdBy: String? = nil, nextRunAt: Date? = nil,
        finishedAt: Date? = nil, runs: Int = 0, lastRun: LastRun? = nil, runnerId: String? = nil,
        runnerName: String? = nil, runnerIcon: String? = nil, runRequestedAt: Date? = nil
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
        self.poolId = poolId
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
        self.runnerId = runnerId
        self.runnerName = runnerName
        self.runnerIcon = runnerIcon
        self.runRequestedAt = runRequestedAt
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
        poolId = string(.poolId).flatMap { $0.isEmpty ? nil : $0 }
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
        runnerId = string(.runnerId).flatMap { $0.isEmpty ? nil : $0 }
        runnerName = string(.runnerName).flatMap { $0.isEmpty ? nil : $0 }
        runnerIcon = string(.runnerIcon).flatMap { $0.isEmpty ? nil : $0 }
        runRequestedAt = date(.runRequestedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, text, at, cron, timezone, whenText, threadId, cwd, accountId, poolId, model, effort, permissionMode
        case paused, createdAt, updatedAt, createdBy, nextRunAt, finishedAt, runs, lastRun
        case runnerId, runnerName, runnerIcon, runRequestedAt
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

    /// Runs on a runner other than `selfRunnerId` (the one answering, from
    /// `runners.list`). Without a runner on either side it's this one's: an
    /// older runner sends no `runnerId`, and one that can't list runners
    /// has only itself.
    public func runsElsewhere(than selfRunnerId: String?) -> Bool {
        guard let runnerId, let selfRunnerId else { return false }
        return runnerId != selfRunnerId
    }
}

/// A runner Threadbear knows of, from the backend (`runners.list`): where a
/// schedule can run.
public struct RunnerInfo: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    /// "m5", "bruce": the Mac's hostname by default.
    public var name: String
    /// An SF Symbol for its Mac ("laptopcomputer", "macmini"), from the
    /// runner's model or its `sync.icon`. Nil from a runner before icons.
    public var icon: String?
    /// Heard from in the last few minutes.
    public var online: Bool
    public var lastSeenAt: Date?
    /// The runner answering, the one this app talks to.
    public var isSelf: Bool
    /// What its last heartbeat said, for the Runners panel. Nil from a
    /// runner before they were passed on (5 Nov).
    public var version: String?
    public var release: String?
    public var startedAt: Date?
    /// An old release finishing its threads in a handover.
    public var draining: Bool

    public init(id: String, name: String, icon: String? = nil, online: Bool = true, lastSeenAt: Date? = nil, isSelf: Bool = false,
                version: String? = nil, release: String? = nil, startedAt: Date? = nil, draining: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.isSelf = isSelf
        self.version = version
        self.release = release
        self.startedAt = startedAt
        self.draining = draining
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0.isEmpty ? nil : $0 } ?? id
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)).flatMap { $0.isEmpty ? nil : $0 }
        isSelf = (try? c.decodeIfPresent(Bool.self, forKey: .isSelf)) ?? false
        // The answering runner is plainly up; anything else unsaid is offline.
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? isSelf
        lastSeenAt = (try? c.decodeIfPresent(String.self, forKey: .lastSeenAt)).flatMap(ISO8601.parse)
        version = (try? c.decodeIfPresent(String.self, forKey: .version)).flatMap { $0.isEmpty ? nil : $0 }
        release = (try? c.decodeIfPresent(String.self, forKey: .release)).flatMap { $0.isEmpty ? nil : $0 }
        startedAt = (try? c.decodeIfPresent(String.self, forKey: .startedAt)).flatMap(ISO8601.parse)
        draining = (try? c.decodeIfPresent(Bool.self, forKey: .draining)) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, online, lastSeenAt, version, release, startedAt, draining
        case isSelf = "self"
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
