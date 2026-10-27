import Foundation

// Types from docs/protocol.md. Decoding is deliberately forgiving: unknown
// fields are ignored and missing optional fields fall back to defaults, so
// the app keeps working when the runner is upgraded first.

public struct Account: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// "claude" or "codex"; kept as a string so a provider this app doesn't
    /// know yet still shows.
    public var provider: String
    /// Codex titles start "Codex · ", so apps that only show this can tell
    /// a Codex login from a Claude one with the same address.
    public var title: String
    public var configDir: String
    /// The full id a thread with no model runs on, once the runner knows
    /// (the account's settings, corrected by the first turn seen).
    public var defaultModel: String?
    /// The CLI's model picker, in its order, once the runner has asked it.
    public var models: [ModelChoice]
    /// The account's own effort level; nil is each model's own.
    public var defaultEffort: String?
    /// The bare address, to build labels from with `provider`.
    public var email: String?
    /// "Max", "Team", "Pro Lite".
    public var plan: String?
    /// Mike's note for the account ("Convex work only").
    public var note: String?
    /// Nil when nothing is known, and always from runners older than step 4.
    public var usage: AccountUsage?

    public init(
        id: String, provider: String = "claude", title: String, configDir: String = "", defaultModel: String? = nil, models: [ModelChoice] = [],
        defaultEffort: String? = nil, email: String? = nil, plan: String? = nil, note: String? = nil, usage: AccountUsage? = nil
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.configDir = configDir
        self.defaultModel = defaultModel
        self.models = models
        self.defaultEffort = defaultEffort
        self.email = email
        self.plan = plan
        self.note = note
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "claude"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? id
        configDir = (try? c.decodeIfPresent(String.self, forKey: .configDir)) ?? ""
        defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
        models = c.lossyArray(ModelChoice.self, forKey: .models)
        defaultEffort = try? c.decodeIfPresent(String.self, forKey: .defaultEffort)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        // A usage block this app can't read leaves the account without one
        // rather than dropping the account.
        usage = try? c.decodeIfPresent(AccountUsage.self, forKey: .usage)
    }
}

/// How much room an account has left, from Token Stats' file or the
/// account's own turns.
public struct AccountUsage: Sendable, Hashable, Codable {
    public var windows: [UsageWindow]
    /// When the newest reading in it was taken.
    public var readAt: Date?
    /// "tokenStats" or "live".
    public var source: String
    /// Token Stats has gone quiet and there's no live reading since.
    public var stale: Bool
    /// The provider says this login is at its limit.
    public var blocked: Bool
    /// Token Stats' own note ("64,390 credits · 2 limit resets available").
    public var notice: String?

    public init(windows: [UsageWindow], readAt: Date? = nil, source: String = "tokenStats", stale: Bool = false, blocked: Bool = false, notice: String? = nil) {
        self.windows = windows
        self.readAt = readAt
        self.source = source
        self.stale = stale
        self.blocked = blocked
        self.notice = notice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = c.lossyArray(UsageWindow.self, forKey: .windows)
        readAt = ((try? c.decodeIfPresent(String.self, forKey: .readAt)) ?? nil).flatMap(ISO8601.parse)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "tokenStats"
        stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
        blocked = (try? c.decodeIfPresent(Bool.self, forKey: .blocked)) ?? false
        notice = try? c.decodeIfPresent(String.self, forKey: .notice)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windows, forKey: .windows)
        try c.encodeIfPresent(readAt.map(ISO8601.format), forKey: .readAt)
        try c.encode(source, forKey: .source)
        if stale { try c.encode(stale, forKey: .stale) }
        if blocked { try c.encode(blocked, forKey: .blocked) }
        try c.encodeIfPresent(notice, forKey: .notice)
    }

    enum CodingKeys: String, CodingKey { case windows, readAt, source, stale, blocked, notice }
}

/// One limit: "5-hour 89% left, resets at 1 pm".
public struct UsageWindow: Sendable, Hashable, Codable {
    /// "five_hour", "weekly", "weekly_model", "daily", "monthly",
    /// "allowance" or "other"; a string so new kinds still show by title.
    public var kind: String
    public var title: String
    /// 0 to 100, may be fractional.
    public var remainingPercent: Double
    public var resetsAt: Date?
    /// "$132.79 left".
    public var detail: String?

    public init(kind: String, title: String, remainingPercent: Double, resetsAt: Date? = nil, detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.detail = detail
    }

    /// A window with no percentage can't be shown, so it fails and the
    /// lossy array skips it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remainingPercent = min(100, max(0, try c.decode(Double.self, forKey: .remainingPercent)))
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "other"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? kind
        resetsAt = ((try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil).flatMap(ISO8601.parse)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(remainingPercent, forKey: .remainingPercent)
        try c.encodeIfPresent(resetsAt.map(ISO8601.format), forKey: .resetsAt)
        try c.encodeIfPresent(detail, forKey: .detail)
    }

    enum CodingKeys: String, CodingKey { case kind, title, remainingPercent, resetsAt, detail }
}

/// What the runner knows about one CLI: the version new sessions start,
/// the latest one, and any update going on (`clis.list`, `clis.updated`).
public struct CliStatus: Sendable, Hashable, Decodable, Identifiable {
    public struct InUse: Sendable, Hashable, Decodable {
        public var version: String
        public var threadIds: [String]

        public init(version: String, threadIds: [String] = []) {
            self.version = version
            self.threadIds = threadIds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            threadIds = (try? c.decodeIfPresent([String].self, forKey: .threadIds)) ?? []
        }

        enum CodingKeys: String, CodingKey { case version, threadIds }
    }

    /// Why an update wasn't installed by itself.
    public struct Hold: Sendable, Hashable, Decodable {
        public var version: String
        public var reason: String
        public var missing: [String]

        public init(version: String, reason: String, missing: [String] = []) {
            self.version = version
            self.reason = reason
            self.missing = missing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
            missing = (try? c.decodeIfPresent([String].self, forKey: .missing)) ?? []
        }

        enum CodingKeys: String, CodingKey { case version, reason, missing }
    }

    public struct Update: Sendable, Hashable, Decodable {
        /// "waiting", "running", "succeeded", "unchanged" or "failed".
        public var state: String
        public var targetVersion: String?
        public var waitingFor: [String]
        public var finishedAt: Date?
        public var message: String?

        public init(state: String, targetVersion: String? = nil, waitingFor: [String] = [], finishedAt: Date? = nil, message: String? = nil) {
            self.state = state
            self.targetVersion = targetVersion
            self.waitingFor = waitingFor
            self.finishedAt = finishedAt
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "unknown"
            targetVersion = try? c.decodeIfPresent(String.self, forKey: .targetVersion)
            waitingFor = (try? c.decodeIfPresent([String].self, forKey: .waitingFor)) ?? []
            finishedAt = ((try? c.decodeIfPresent(String.self, forKey: .finishedAt)) ?? nil).flatMap(ISO8601.parse)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
        }

        enum CodingKeys: String, CodingKey { case state, targetVersion, waitingFor, finishedAt, message }
    }

    public var id: String { provider }
    public var provider: String
    /// The binary new sessions start.
    public var path: String
    /// "threadbare" (Codex's own copies), "cli" (Claude's installer) or
    /// "none" (a path set by hand, never updated).
    public var managedBy: String
    public var installedVersion: String?
    public var latestVersion: String?
    /// "current", "behind", "held", "unknown" or "missing".
    public var status: String
    /// "auto", "notify" or "off".
    public var policy: String
    public var inUse: [InUse]
    /// Codex: the kept version "Go back" returns to.
    public var previousVersion: String?
    public var checkedAt: Date?
    public var hold: Hold?
    public var update: Update?

    public init(
        provider: String, path: String = "", managedBy: String = "cli", installedVersion: String? = nil, latestVersion: String? = nil,
        status: String = "unknown", policy: String = "auto", inUse: [InUse] = [], previousVersion: String? = nil,
        checkedAt: Date? = nil, hold: Hold? = nil, update: Update? = nil
    ) {
        self.provider = provider
        self.path = path
        self.managedBy = managedBy
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.status = status
        self.policy = policy
        self.inUse = inUse
        self.previousVersion = previousVersion
        self.checkedAt = checkedAt
        self.hold = hold
        self.update = update
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        managedBy = (try? c.decodeIfPresent(String.self, forKey: .managedBy)) ?? "cli"
        installedVersion = try? c.decodeIfPresent(String.self, forKey: .installedVersion)
        latestVersion = try? c.decodeIfPresent(String.self, forKey: .latestVersion)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        policy = (try? c.decodeIfPresent(String.self, forKey: .policy)) ?? "auto"
        inUse = c.lossyArray(InUse.self, forKey: .inUse)
        previousVersion = try? c.decodeIfPresent(String.self, forKey: .previousVersion)
        checkedAt = ((try? c.decodeIfPresent(String.self, forKey: .checkedAt)) ?? nil).flatMap(ISO8601.parse)
        hold = try? c.decodeIfPresent(Hold.self, forKey: .hold)
        update = try? c.decodeIfPresent(Update.self, forKey: .update)
    }

    enum CodingKeys: String, CodingKey {
        case provider, path, managedBy, installedVersion, latestVersion, status, policy, inUse, previousVersion, checkedAt, hold, update
    }
}

/// One row of a CLI's model picker: `id` is what a thread's model is set
/// to, `model` the full id it runs as.
public struct ModelChoice: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var model: String
    public var title: String
    public var description: String?
    /// Empty when the model takes no effort level.
    public var effortLevels: [String]
    /// The model's own level, when the CLI says (Codex).
    public var defaultEffort: String?

    public init(id: String, model: String, title: String, description: String? = nil, effortLevels: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.model = model
        self.title = title
        self.description = description
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        effortLevels = try c.decodeIfPresent([String].self, forKey: .effortLevels) ?? []
        defaultEffort = try? c.decodeIfPresent(String.self, forKey: .defaultEffort)
    }
}

public enum ThreadStatus: String, Sendable, Hashable, Codable {
    case idle, starting, running, waiting, error, stopped

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadStatus(rawValue: raw) ?? .idle
    }

    /// A turn is underway (or about to be).
    public var isBusy: Bool { self == .running || self == .starting || self == .waiting }
}

public enum PermissionMode: String, Sendable, Hashable, Codable {
    case full, ask

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PermissionMode(rawValue: raw) ?? .full
    }
}

public struct ImageRef: Sendable, Hashable, Codable {
    public var path: String
    public var mediaType: String
    public var width: Int?
    public var height: Int?

    public init(path: String, mediaType: String, width: Int? = nil, height: Int? = nil) {
        self.path = path
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType) ?? "image/png"
        width = try c.decodeIfPresent(Double.self, forKey: .width).map { Int($0) }
        height = try c.decodeIfPresent(Double.self, forKey: .height).map { Int($0) }
    }
}

/// A panel a patch gives a thread: a page or picture shown beside the
/// transcript (docs/protocol.md, "Panels"). The runner works them out from
/// the thread's folder.
public struct Panel: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case url, image

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .url
        }
    }

    public var id: String
    public var title: String
    public var kind: Kind
    /// What a `url` panel shows, and what Open in browser opens.
    public var url: String?
    /// The patch it came from: "convex", "xcode".
    public var patch: String
    /// One line about it: the deployment, the project.
    public var note: String?

    public init(id: String, title: String, kind: Kind = .url, url: String? = nil, patch: String = "", note: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.url = url
        self.patch = patch
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .url
        url = try c.decodeIfPresent(String.self, forKey: .url)
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// The page as a URL, when it is one.
    public var pageURL: URL? { url.flatMap(URL.init(string:)) }
}

/// An action a patch gives a thread: a chip above the composer that runs
/// a command in the thread's folder or sends a canned prompt.
public struct Action: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case command, prompt

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .command
        }
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var command: String?
    public var prompt: String?
    public var patch: String
    public var note: String?

    public init(id: String, title: String, kind: Kind = .command, command: String? = nil, prompt: String? = nil, patch: String = "", note: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.command = command
        self.prompt = prompt
        self.patch = patch
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .command
        command = try c.decodeIfPresent(String.self, forKey: .command)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// A hook a patch gives a thread: a command the runner runs by itself
/// after a turn, posted into the transcript like an action.
public struct Hook: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var on: String
    public var command: String
    public var edited: String?
    public var tell: String
    public var patch: String
    public var note: String?

    public init(id: String, title: String, on: String = "turn.end", command: String = "", edited: String? = nil, tell: String = "failures", patch: String = "", note: String? = nil) {
        self.id = id
        self.title = title
        self.on = on
        self.command = command
        self.edited = edited
        self.tell = tell
        self.patch = patch
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        on = try c.decodeIfPresent(String.self, forKey: .on) ?? "turn.end"
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        edited = try c.decodeIfPresent(String.self, forKey: .edited)
        tell = try c.decodeIfPresent(String.self, forKey: .tell) ?? "failures"
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// A patch that applies to a thread's folder: built in, from
/// `~/.threadbear/patches`, or the project's own.
public struct PatchInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var source: String
    public var file: String?
    public var error: String?

    public init(id: String, source: String = "project", file: String? = nil, error: String? = nil) {
        self.id = id
        self.source = source
        self.file = file
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "project"
        file = try c.decodeIfPresent(String.self, forKey: .file)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// What `actions.run` gives back: the turn a prompt action started, or how
/// a command action went (its output is in the transcript at `seq`).
public struct ActionRunResult: Sendable, Hashable, Decodable {
    public var turnId: String?
    public var ok: Bool?
    public var exitCode: Int?
    public var durationMs: Double?
    public var seq: Int?
}

/// What `panels.render` gives back for an image panel: the picture, or a
/// note saying why there isn't one.
public struct PanelRender: Sendable, Hashable, Decodable {
    public var image: ImageRef?
    public var note: String?

    public init(image: ImageRef? = nil, note: String? = nil) {
        self.image = image
        self.note = note
    }
}

/// A sub-agent the thread's agent started (Claude's Agent tool), foreground
/// or background. The runner follows it from the CLI's task events, so its
/// status and activity change while it runs; `threads.subagent` reads what
/// it did.
public struct Subagent: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        case running, completed, failed, stopped

        /// A status this app doesn't know is shown as stopped.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .stopped
        }
    }

    public var id: String
    /// The tool.call in the thread that started it.
    public var itemId: String?
    /// The sub-agent that started this one, when a sub-agent did.
    public var parentId: String?
    public var description: String
    /// "general-purpose", "Explore", "fork".
    public var agentType: String?
    public var status: Status
    public var background: Bool
    /// While running: what it's doing, in the CLI's words.
    public var activity: String?
    /// Once finished: what it reported, one line.
    public var summary: String?
    public var toolUses: Int?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: String, itemId: String? = nil, parentId: String? = nil, description: String, agentType: String? = nil,
        status: Status = .running, background: Bool = false, activity: String? = nil, summary: String? = nil,
        toolUses: Int? = nil, startedAt: Date = Date(), endedAt: Date? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.parentId = parentId
        self.description = description
        self.agentType = agentType
        self.status = status
        self.background = background
        self.activity = activity
        self.summary = summary
        self.toolUses = toolUses
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .stopped
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        toolUses = try c.decodeIfPresent(Double.self, forKey: .toolUses).map { Int($0) }
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt).flatMap(ISO8601.parse) ?? Date(timeIntervalSince1970: 0)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt).flatMap(ISO8601.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(itemId, forKey: .itemId)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(agentType, forKey: .agentType)
        try c.encode(status, forKey: .status)
        try c.encode(background, forKey: .background)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(toolUses, forKey: .toolUses)
        try c.encode(ISO8601.format(startedAt), forKey: .startedAt)
        try c.encodeIfPresent(endedAt.map(ISO8601.format), forKey: .endedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, itemId, parentId, description, agentType, status, background, activity, summary, toolUses, startedAt, endedAt
    }

    public var isRunning: Bool { status == .running }
}

/// What `threads.subagent` returns: the sub-agent as the thread's list has
/// it (nil once the list has dropped it) and what it has done, as events.
public struct SubagentTranscript: Sendable, Decodable {
    public var subagent: Subagent?
    public var events: [Event]

    public init(subagent: Subagent?, events: [Event]) {
        self.subagent = subagent
        self.events = events
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subagent = try? c.decodeIfPresent(Subagent.self, forKey: .subagent)
        events = c.lossyArray(Event.self, forKey: .events)
    }

    enum CodingKeys: String, CodingKey {
        case subagent, events
    }
}

/// Work the live CLI is still running in the background: a sub-agent or a
/// shell job started with run_in_background, a Monitor. `finished` once it
/// has ended and the agent is about to start a turn to read its result.
public struct BackgroundTask: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case agent, shell, monitor, other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public var kind: Kind
    /// The CLI's own words: the sub-agent's brief, the command. May be empty.
    public var description: String
    public var finished: Bool

    public init(kind: Kind, description: String, finished: Bool = false) {
        self.kind = kind
        self.description = description
        self.finished = finished
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(description, forKey: .description)
        if finished { try c.encode(true, forKey: .finished) }
    }

    enum CodingKeys: String, CodingKey {
        case kind, description, finished
    }
}

public struct ThreadSummary: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    public var accountId: String
    public var provider: String
    public var model: String?
    /// The level chosen for the thread; nil is the model's own.
    public var effort: String?
    /// What the CLI actually ran the last turn on and at, once one has run.
    public var modelInUse: String?
    public var effortInUse: String?
    public var permissionMode: PermissionMode
    public var status: ThreadStatus
    public var live: Bool
    public var needsYou: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivityAt: Date
    public var snoozedUntil: Date?
    /// Hibernating until the runner next starts (snoozedUntil is then a
    /// date far off, which the runner never reaches).
    public var snoozedUntilRestart: Bool
    public var archivedAt: Date?
    public var preview: String
    public var lastSeq: Int
    public var lastSeenSeq: Int
    public var nativeSessionId: String?
    public var contextTokens: Int?
    /// The model's context window, when the CLI reports it.
    public var contextWindow: Int?
    public var costUsd: Double?
    /// Panels, actions and patches from the folder; empty for most threads.
    public var panels: [Panel]
    public var actions: [Action]
    public var hooks: [Hook]
    public var patches: [PatchInfo]
    /// Background sub-agents and shell jobs the CLI is still running (and
    /// ones just finished whose result it's about to read). Empty when none.
    public var background: [BackgroundTask]
    /// The sub-agents the agent has started: the newest 20, oldest first.
    public var subagents: [Subagent]

    public init(
        id: String, title: String, cwd: String = "~/dev/me/misc", accountId: String = "claude-main",
        provider: String = "claude", model: String? = nil, permissionMode: PermissionMode = .full,
        status: ThreadStatus = .idle, live: Bool = false, needsYou: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(), lastActivityAt: Date = Date(),
        snoozedUntil: Date? = nil, snoozedUntilRestart: Bool = false, archivedAt: Date? = nil, preview: String = "",
        lastSeq: Int = 0, lastSeenSeq: Int = 0, nativeSessionId: String? = nil,
        contextTokens: Int? = nil, costUsd: Double? = nil,
        effort: String? = nil, modelInUse: String? = nil, effortInUse: String? = nil, contextWindow: Int? = nil,
        panels: [Panel] = [], actions: [Action] = [], hooks: [Hook] = [], patches: [PatchInfo] = [], background: [BackgroundTask] = [],
        subagents: [Subagent] = []
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.accountId = accountId
        self.provider = provider
        self.model = model
        self.effort = effort
        self.modelInUse = modelInUse
        self.effortInUse = effortInUse
        self.permissionMode = permissionMode
        self.status = status
        self.live = live
        self.needsYou = needsYou
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.snoozedUntil = snoozedUntil
        self.snoozedUntilRestart = snoozedUntilRestart
        self.archivedAt = archivedAt
        self.preview = preview
        self.lastSeq = lastSeq
        self.lastSeenSeq = lastSeenSeq
        self.nativeSessionId = nativeSessionId
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUsd = costUsd
        self.panels = panels
        self.actions = actions
        self.hooks = hooks
        self.patches = patches
        self.background = background
        self.subagents = subagents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date? {
            guard let text = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return ISO8601.parse(text)
        }
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        modelInUse = try c.decodeIfPresent(String.self, forKey: .modelInUse)
        effortInUse = try c.decodeIfPresent(String.self, forKey: .effortInUse)
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .full
        status = try c.decodeIfPresent(ThreadStatus.self, forKey: .status) ?? .idle
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
        let created = try date(.createdAt) ?? Date(timeIntervalSince1970: 0)
        createdAt = created
        updatedAt = try date(.updatedAt) ?? created
        lastActivityAt = try date(.lastActivityAt) ?? updatedAt
        snoozedUntil = try date(.snoozedUntil)
        snoozedUntilRestart = ((try? c.decodeIfPresent(Bool.self, forKey: .snoozedUntilRestart)) ?? nil) ?? false
        archivedAt = try date(.archivedAt)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        lastSeenSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeenSeq) ?? 0
        nativeSessionId = try c.decodeIfPresent(String.self, forKey: .nativeSessionId)
        contextTokens = try c.decodeIfPresent(Double.self, forKey: .contextTokens).map { Int($0) }
        contextWindow = ((try? c.decodeIfPresent(Double.self, forKey: .contextWindow)) ?? nil).map { Int($0) }
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        panels = c.lossyArray(Panel.self, forKey: .panels)
        actions = c.lossyArray(Action.self, forKey: .actions)
        hooks = c.lossyArray(Hook.self, forKey: .hooks)
        patches = c.lossyArray(PatchInfo.self, forKey: .patches)
        background = c.lossyArray(BackgroundTask.self, forKey: .background)
        subagents = c.lossyArray(Subagent.self, forKey: .subagents)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(modelInUse, forKey: .modelInUse)
        try c.encodeIfPresent(effortInUse, forKey: .effortInUse)
        try c.encode(permissionMode, forKey: .permissionMode)
        try c.encode(status, forKey: .status)
        try c.encode(live, forKey: .live)
        try c.encode(needsYou, forKey: .needsYou)
        try c.encode(ISO8601.format(createdAt), forKey: .createdAt)
        try c.encode(ISO8601.format(updatedAt), forKey: .updatedAt)
        try c.encode(ISO8601.format(lastActivityAt), forKey: .lastActivityAt)
        try c.encodeIfPresent(snoozedUntil.map(ISO8601.format), forKey: .snoozedUntil)
        if snoozedUntilRestart { try c.encode(true, forKey: .snoozedUntilRestart) }
        try c.encodeIfPresent(archivedAt.map(ISO8601.format), forKey: .archivedAt)
        try c.encode(preview, forKey: .preview)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encode(lastSeenSeq, forKey: .lastSeenSeq)
        try c.encodeIfPresent(nativeSessionId, forKey: .nativeSessionId)
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(costUsd, forKey: .costUsd)
        if !panels.isEmpty { try c.encode(panels, forKey: .panels) }
        if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
        if !hooks.isEmpty { try c.encode(hooks, forKey: .hooks) }
        if !patches.isEmpty { try c.encode(patches, forKey: .patches) }
        if !background.isEmpty { try c.encode(background, forKey: .background) }
        if !subagents.isEmpty { try c.encode(subagents, forKey: .subagents) }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, accountId, provider, model, effort, modelInUse, effortInUse, permissionMode, status, live, needsYou
        case createdAt, updatedAt, lastActivityAt, snoozedUntil, snoozedUntilRestart, archivedAt, preview
        case lastSeq, lastSeenSeq, nativeSessionId, contextTokens, contextWindow, costUsd, panels, actions, hooks, patches, background, subagents
    }

    /// Still being worked on between turns: background sub-agents or jobs
    /// are running (or just finished, with their result still to be read)
    /// and no turn is underway to show for it.
    public var isWorkingInBackground: Bool { !background.isEmpty && !status.isBusy }

    public var isArchived: Bool { archivedAt != nil }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }
}

public struct RunnerDefaults: Sendable, Hashable, Codable {
    public var cwd: String
    public var accountId: String
    /// The model a new Claude thread gets when it names none (runner.json's
    /// `defaults.model`; a dev runner sets the cheapest). Nil: the account's.
    public var model: String?
    /// The same per provider ("claude", "codex"); empty from older runners.
    public var models: [String: String]
    /// The effort a new thread gets per provider; missing: the model's own.
    public var efforts: [String: String]

    public init(cwd: String, accountId: String, model: String? = nil, models: [String: String] = [:], efforts: [String: String] = [:]) {
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.models = models
        self.efforts = efforts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        accountId = (try? c.decodeIfPresent(String.self, forKey: .accountId)) ?? ""
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        models = Self.strings(c, .models)
        efforts = Self.strings(c, .efforts)
    }

    /// The model a new thread on `provider` gets when it names none.
    public func model(for provider: String) -> String? {
        models[provider] ?? (provider == "claude" ? model : nil)
    }

    // A map of strings, skipping values that aren't (a provider this app
    // doesn't know may carry something else).
    private static func strings(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: String] {
        guard let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: key)) ?? nil else { return [:] }
        return raw.compactMapValues(\.stringValue)
    }

    enum CodingKeys: String, CodingKey { case cwd, accountId, model, models, efforts }
}

public struct HelloResult: Sendable, Hashable, Decodable {
    public var runnerVersion: String
    public var `protocol`: Int
    public var accounts: [Account]
    public var defaults: RunnerDefaults
    /// Empty from runners older than step 4 (they have no `clis.*` either).
    public var clis: [CliStatus]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runnerVersion = try c.decodeIfPresent(String.self, forKey: .runnerVersion) ?? "?"
        `protocol` = try c.decodeIfPresent(Int.self, forKey: .protocol) ?? 1
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        defaults = (try? c.decodeIfPresent(RunnerDefaults.self, forKey: .defaults))
            ?? RunnerDefaults(cwd: "", accountId: accounts.first?.id ?? "claude-main")
        if defaults.accountId.isEmpty { defaults.accountId = accounts.first?.id ?? "claude-main" }
        clis = c.lossyArray(CliStatus.self, forKey: .clis)
    }

    enum CodingKeys: String, CodingKey {
        case runnerVersion, `protocol`, accounts, defaults, clis
    }
}

/// Fast parser and formatter for the protocol's ISO 8601 UTC strings.
public enum ISO8601 {
    /// Parses "2026-10-26T13:44:00Z", with optional fractional seconds and a
    /// "+hh:mm" offset. Hand-rolled because thread lists parse thousands of these.
    public static func parse(_ text: String) -> Date? {
        let utf8 = Array(text.utf8)
        guard utf8.count >= 19 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard index < utf8.count else { return nil }
                let byte = utf8[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < utf8.count, utf8[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 48, utf8[index] <= 57 {
                fraction += Double(utf8[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        if index < utf8.count {
            let sign = utf8[index]
            if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                let rest = Array(utf8[(index + 1)...]).filter { $0 != UInt8(ascii: ":") }
                guard rest.count >= 4 else { return nil }
                let hours = Int(rest[0] - 48) * 10 + Int(rest[1] - 48)
                let minutes = Int(rest[2] - 48) * 10 + Int(rest[3] - 48)
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == UInt8(ascii: "+") ? 1 : -1)
            }
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// "2026-10-26T13:44:00.250Z". The trailing Z matters: without it the
    /// runner's `Date.parse` reads the time as local, which put snoozes off
    /// by the time zone.
    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // Howard Hinnant's days_from_civil.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
