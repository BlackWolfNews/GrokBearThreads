import Foundation

// Types from docs/protocol.md. Decoding is deliberately forgiving: unknown
// fields are ignored and missing optional fields fall back to defaults, so
// the app keeps working when the runner is upgraded first.

public struct Account: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var provider: String
    public var title: String
    public var configDir: String
    /// The full id a thread with no model runs on, once the runner knows
    /// (the account's settings, corrected by the first turn seen).
    public var defaultModel: String?
    /// The CLI's model picker, in its order, once the runner has asked it.
    public var models: [ModelChoice]

    public init(id: String, provider: String = "claude", title: String, configDir: String = "", defaultModel: String? = nil, models: [ModelChoice] = []) {
        self.id = id
        self.provider = provider
        self.title = title
        self.configDir = configDir
        self.defaultModel = defaultModel
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        configDir = try c.decodeIfPresent(String.self, forKey: .configDir) ?? ""
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        models = c.lossyArray(ModelChoice.self, forKey: .models)
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

    public init(id: String, model: String, title: String, description: String? = nil, effortLevels: [String] = []) {
        self.id = id
        self.model = model
        self.title = title
        self.description = description
        self.effortLevels = effortLevels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        effortLevels = try c.decodeIfPresent([String].self, forKey: .effortLevels) ?? []
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
    public var archivedAt: Date?
    public var preview: String
    public var lastSeq: Int
    public var lastSeenSeq: Int
    public var nativeSessionId: String?
    public var contextTokens: Int?
    public var costUsd: Double?
    /// Panels, actions and patches from the folder; empty for most threads.
    public var panels: [Panel]
    public var actions: [Action]
    public var hooks: [Hook]
    public var patches: [PatchInfo]
    /// Background sub-agents and shell jobs the CLI is still running (and
    /// ones just finished whose result it's about to read). Empty when none.
    public var background: [BackgroundTask]

    public init(
        id: String, title: String, cwd: String = "~/dev/me/misc", accountId: String = "claude-main",
        provider: String = "claude", model: String? = nil, permissionMode: PermissionMode = .full,
        status: ThreadStatus = .idle, live: Bool = false, needsYou: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(), lastActivityAt: Date = Date(),
        snoozedUntil: Date? = nil, archivedAt: Date? = nil, preview: String = "",
        lastSeq: Int = 0, lastSeenSeq: Int = 0, nativeSessionId: String? = nil,
        contextTokens: Int? = nil, costUsd: Double? = nil,
        effort: String? = nil, modelInUse: String? = nil, effortInUse: String? = nil, panels: [Panel] = [],
        actions: [Action] = [], hooks: [Hook] = [], patches: [PatchInfo] = [], background: [BackgroundTask] = []
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
        self.archivedAt = archivedAt
        self.preview = preview
        self.lastSeq = lastSeq
        self.lastSeenSeq = lastSeenSeq
        self.nativeSessionId = nativeSessionId
        self.contextTokens = contextTokens
        self.costUsd = costUsd
        self.panels = panels
        self.actions = actions
        self.hooks = hooks
        self.patches = patches
        self.background = background
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
        archivedAt = try date(.archivedAt)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        lastSeenSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeenSeq) ?? 0
        nativeSessionId = try c.decodeIfPresent(String.self, forKey: .nativeSessionId)
        contextTokens = try c.decodeIfPresent(Double.self, forKey: .contextTokens).map { Int($0) }
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        panels = c.lossyArray(Panel.self, forKey: .panels)
        actions = c.lossyArray(Action.self, forKey: .actions)
        hooks = c.lossyArray(Hook.self, forKey: .hooks)
        patches = c.lossyArray(PatchInfo.self, forKey: .patches)
        background = c.lossyArray(BackgroundTask.self, forKey: .background)
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
        try c.encodeIfPresent(archivedAt.map(ISO8601.format), forKey: .archivedAt)
        try c.encode(preview, forKey: .preview)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encode(lastSeenSeq, forKey: .lastSeenSeq)
        try c.encodeIfPresent(nativeSessionId, forKey: .nativeSessionId)
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(costUsd, forKey: .costUsd)
        if !panels.isEmpty { try c.encode(panels, forKey: .panels) }
        if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
        if !hooks.isEmpty { try c.encode(hooks, forKey: .hooks) }
        if !patches.isEmpty { try c.encode(patches, forKey: .patches) }
        if !background.isEmpty { try c.encode(background, forKey: .background) }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, accountId, provider, model, effort, modelInUse, effortInUse, permissionMode, status, live, needsYou
        case createdAt, updatedAt, lastActivityAt, snoozedUntil, archivedAt, preview
        case lastSeq, lastSeenSeq, nativeSessionId, contextTokens, costUsd, panels, actions, hooks, patches, background
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
    /// The model a new thread gets when it names none (runner.json's
    /// `defaults.model`; a dev runner sets the cheapest). Nil: the account's.
    public var model: String?

    public init(cwd: String, accountId: String, model: String? = nil) {
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
    }
}

public struct HelloResult: Sendable, Hashable, Decodable {
    public var runnerVersion: String
    public var `protocol`: Int
    public var accounts: [Account]
    public var defaults: RunnerDefaults

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runnerVersion = try c.decodeIfPresent(String.self, forKey: .runnerVersion) ?? "?"
        `protocol` = try c.decodeIfPresent(Int.self, forKey: .protocol) ?? 1
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        defaults = try c.decodeIfPresent(RunnerDefaults.self, forKey: .defaults)
            ?? RunnerDefaults(cwd: "", accountId: accounts.first?.id ?? "claude-main")
    }

    enum CodingKeys: String, CodingKey {
        case runnerVersion, `protocol`, accounts, defaults
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
