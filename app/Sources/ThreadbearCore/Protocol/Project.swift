import Foundation

/// Who put a thread in a project, or made one (docs/protocol.md, "Projects").
/// A value from a newer runner reads as `.agent`, the middle of the three:
/// neither Mike's own choice nor the librarian's guess.
public enum ProjectAuthor: String, Sendable, Hashable, Codable {
    case mike, agent, librarian

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProjectAuthor(rawValue: raw) ?? .agent
    }
}

/// A project a thread is in, as its summary shows it.
public struct ThreadProject: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var by: ProjectAuthor
    /// Mike put it there (or an agent was told to): the librarian won't
    /// take it out.
    public var pinned: Bool
    public var at: Date?

    public init(id: String, title: String, by: ProjectAuthor = .librarian, pinned: Bool = false, at: Date? = nil) {
        self.id = id
        self.title = title
        self.by = by
        self.pinned = pinned
        self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        by = (try? c.decodeIfPresent(ProjectAuthor.self, forKey: .by)).flatMap { $0 } ?? .librarian
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)).flatMap { $0 } ?? false
        at = (try? c.decodeIfPresent(String.self, forKey: .at)).flatMap { $0 }.flatMap(ISO8601.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(by, forKey: .by)
        if pinned { try c.encode(true, forKey: .pinned) }
        try c.encodeIfPresent(at.map(ISO8601.format), forKey: .at)
    }

    enum CodingKeys: String, CodingKey { case id, title, by, pinned, at }
}

/// A grouping above folders that carries goals, state and notes forward.
public struct Project: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var title: String
    /// Absolute paths, in the order patches load from them.
    public var folders: [String]
    public var goals: String
    public var state: String
    public var notes: String
    public var createdBy: ProjectAuthor
    /// The thread whose agent or look made it.
    public var createdByThread: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var stateUpdatedAt: Date?
    public var archived: Bool
    /// Absent until the librarian has found or picked one.
    public var icon: ProjectIcon?
    /// Threads in it, put away ones included.
    public var threadCount: Int
    public var lastActivityAt: Date?

    public init(
        id: String, title: String, folders: [String] = [], goals: String = "", state: String = "", notes: String = "",
        createdBy: ProjectAuthor = .librarian, createdByThread: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
        stateUpdatedAt: Date? = nil, archived: Bool = false, icon: ProjectIcon? = nil, threadCount: Int = 0, lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.folders = folders
        self.goals = goals
        self.state = state
        self.notes = notes
        self.createdBy = createdBy
        self.createdByThread = createdByThread
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stateUpdatedAt = stateUpdatedAt
        self.archived = archived
        self.icon = icon
        self.threadCount = threadCount
        self.lastActivityAt = lastActivityAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        func date(_ key: CodingKeys) -> Date? { string(key).flatMap(ISO8601.parse) }
        id = try c.decode(String.self, forKey: .id)
        title = string(.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled project"
        folders = c.lossyArray(String.self, forKey: .folders)
        goals = string(.goals) ?? ""
        state = string(.state) ?? ""
        notes = string(.notes) ?? ""
        createdBy = (try? c.decodeIfPresent(ProjectAuthor.self, forKey: .createdBy)).flatMap { $0 } ?? .librarian
        createdByThread = string(.createdByThread)
        createdAt = date(.createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = date(.updatedAt) ?? createdAt
        stateUpdatedAt = date(.stateUpdatedAt)
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)).flatMap { $0 } ?? false
        icon = (try? c.decodeIfPresent(ProjectIcon.self, forKey: .icon)).flatMap { $0 }
        threadCount = c.lenientInt(forKey: .threadCount) ?? 0
        lastActivityAt = date(.lastActivityAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, folders, goals, state, notes, createdBy, createdByThread, createdAt, updatedAt, stateUpdatedAt
        case archived, icon, threadCount, lastActivityAt
    }
}

/// A project's icon (docs/protocol.md, "Icons"): a picture copied into the
/// runner's data dir, else an SF Symbol. One neither of those can draw is
/// shown as the title's first letter.
public struct ProjectIcon: Sendable, Hashable, Decodable {
    public var image: ImageRef?
    public var symbol: String?
    /// The file the picture was copied from.
    public var from: String?
    /// The librarian's is found and kept up to date by itself; Mike's or an
    /// agent's stays until it's set back to automatic.
    public var by: ProjectAuthor
    public var updatedAt: Date?

    public init(image: ImageRef? = nil, symbol: String? = nil, from: String? = nil, by: ProjectAuthor = .librarian, updatedAt: Date? = nil) {
        self.image = image
        self.symbol = symbol
        self.from = from
        self.by = by
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        image = (try? c.decodeIfPresent(ImageRef.self, forKey: .image)).flatMap { $0 }
        symbol = string(.symbol).flatMap { $0.isEmpty ? nil : $0 }
        from = string(.from)
        by = (try? c.decodeIfPresent(ProjectAuthor.self, forKey: .by)).flatMap { $0 } ?? .librarian
        updatedAt = string(.updatedAt).flatMap(ISO8601.parse)
    }

    enum CodingKeys: String, CodingKey { case image, symbol, from, by, updatedAt }

    /// Chosen by Mike or an agent rather than found.
    public var isChosen: Bool { by != .librarian }
}

// MARK: The librarian

/// Why the librarian looks at a thread. An unknown one from a newer runner
/// reads as `.asked`, which says least.
public enum LibrarianReason: String, Sendable, Hashable, Decodable {
    case firstMessage = "first-message"
    case firstTurn = "first-turn"
    case newFolder = "new-folder"
    case moved
    case catchUp = "catch-up"
    case asked

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LibrarianReason(rawValue: raw) ?? .asked
    }
}

/// A look the librarian will take (or is taking) at a thread.
public struct LibrarianJob: Sendable, Hashable, Decodable {
    public var threadId: String
    public var threadTitle: String
    public var reason: LibrarianReason
    /// The reason in words: "Edited files in ~/dev/me/poddle".
    public var why: String
    public var dueAt: Date?
    /// Only on `current`: when the look began.
    public var startedAt: Date?

    public init(threadId: String, threadTitle: String = "", reason: LibrarianReason = .asked, why: String = "",
                dueAt: Date? = nil, startedAt: Date? = nil) {
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.reason = reason
        self.why = why
        self.dueAt = dueAt
        self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        threadId = try c.decode(String.self, forKey: .threadId)
        threadTitle = string(.threadTitle) ?? ""
        reason = (try? c.decodeIfPresent(LibrarianReason.self, forKey: .reason)).flatMap { $0 } ?? .asked
        why = string(.why) ?? ""
        dueAt = string(.dueAt).flatMap(ISO8601.parse)
        startedAt = string(.startedAt).flatMap(ISO8601.parse)
    }

    enum CodingKeys: String, CodingKey { case threadId, threadTitle, reason, why, dueAt, startedAt }
}

/// Something the librarian did.
public struct LibrarianEntry: Sendable, Hashable, Decodable, Identifiable {
    public enum Outcome: String, Sendable, Hashable, Decodable {
        case joined, created, updated, left, nothing, skipped, failed
        /// From a newer runner.
        case other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .other
        }
    }

    public var id: String
    public var at: Date?
    public var threadId: String
    public var threadTitle: String
    public var reason: LibrarianReason
    public var outcome: Outcome
    /// "Put it in Threadbear", "Made Poddle and put it there".
    public var text: String
    public var projectIds: [String]
    public var costUsd: Double?

    public init(id: String, at: Date? = nil, threadId: String, threadTitle: String = "", reason: LibrarianReason = .asked,
                outcome: Outcome = .nothing, text: String = "", projectIds: [String] = [], costUsd: Double? = nil) {
        self.id = id
        self.at = at
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.reason = reason
        self.outcome = outcome
        self.text = text
        self.projectIds = projectIds
        self.costUsd = costUsd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        id = try c.decode(String.self, forKey: .id)
        at = string(.at).flatMap(ISO8601.parse)
        threadId = string(.threadId) ?? ""
        threadTitle = string(.threadTitle) ?? ""
        reason = (try? c.decodeIfPresent(LibrarianReason.self, forKey: .reason)).flatMap { $0 } ?? .asked
        outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)).flatMap { $0 } ?? .other
        text = string(.text) ?? ""
        projectIds = c.lossyArray(String.self, forKey: .projectIds)
        costUsd = (try? c.decodeIfPresent(Double.self, forKey: .costUsd)).flatMap { $0 }
    }

    enum CodingKeys: String, CodingKey { case id, at, threadId, threadTitle, reason, outcome, text, projectIds, costUsd }
}

/// What the librarian is doing, has done and will do next.
public struct LibrarianStatus: Sendable, Hashable, Decodable {
    public enum State: String, Sendable, Hashable, Decodable {
        case idle, working, paused, off

        /// An unknown state reads as idle: nothing to show, nothing wrong.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .idle
        }
    }

    public var state: State
    /// State `off`: why.
    public var reason: String?
    public var paused: Bool
    public var current: LibrarianJob?
    public var queue: [LibrarianJob]
    public var recent: [LibrarianEntry]
    public var looksToday: Int
    public var spentTodayUsd: Double

    public init(state: State = .idle, reason: String? = nil, paused: Bool = false, current: LibrarianJob? = nil,
                queue: [LibrarianJob] = [], recent: [LibrarianEntry] = [], looksToday: Int = 0, spentTodayUsd: Double = 0) {
        self.state = state
        self.reason = reason
        self.paused = paused
        self.current = current
        self.queue = queue
        self.recent = recent
        self.looksToday = looksToday
        self.spentTodayUsd = spentTodayUsd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)).flatMap { $0 } ?? false
        state = (try? c.decodeIfPresent(State.self, forKey: .state)).flatMap { $0 } ?? (paused ? .paused : .idle)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 }
        current = (try? c.decodeIfPresent(LibrarianJob.self, forKey: .current)).flatMap { $0 }
        queue = c.lossyArray(LibrarianJob.self, forKey: .queue)
        recent = c.lossyArray(LibrarianEntry.self, forKey: .recent)
        looksToday = c.lenientInt(forKey: .looksToday) ?? 0
        spentTodayUsd = (try? c.decodeIfPresent(Double.self, forKey: .spentTodayUsd)).flatMap { $0 } ?? 0
    }

    enum CodingKeys: String, CodingKey { case state, reason, paused, current, queue, recent, looksToday, spentTodayUsd }

    /// What the activity bar's badge counts: the look under way and the
    /// ones waiting.
    public var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }
}
