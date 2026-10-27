import Foundation

/// Typed wrappers for the requests in docs/protocol.md.
public extension RPCClient {
    func hello(client: String = "threadbare-mac", version: String) async throws -> HelloResult {
        try await call("hello", .object(["client": .string(client), "version": .string(version)]))
    }

    func listThreads(include: [ThreadListScope] = [.inbox]) async throws -> [ThreadSummary] {
        let params: JSONValue = .object(["include": .array(include.map { .string($0.rawValue) })])
        return try await call("threads.list", params, as: ThreadsResult.self).threads
    }

    func searchThreads(_ query: String, limit: Int? = nil) async throws -> [ThreadSummary] {
        var params: [String: JSONValue] = ["query": .string(query)]
        if let limit { params["limit"] = .number(Double(limit)) }
        return try await call("threads.search", .object(params), as: ThreadsResult.self).threads
    }

    func createThread(_ request: NewThreadRequest) async throws -> ThreadSummary {
        var params: [String: JSONValue] = ["text": .string(request.text)]
        if !request.images.isEmpty { params["images"] = .array(request.images.map(\.jsonValue)) }
        if let cwd = request.cwd { params["cwd"] = .string(cwd) }
        if let accountId = request.accountId { params["accountId"] = .string(accountId) }
        if let model = request.model { params["model"] = .string(model) }
        if let effort = request.effort { params["effort"] = .string(effort) }
        if let mode = request.permissionMode { params["permissionMode"] = .string(mode.rawValue) }
        if let title = request.title { params["title"] = .string(title) }
        return try await call("threads.create", .object(params), as: ThreadResult.self).thread
    }

    @discardableResult
    func send(threadId: String, text: String, images: [ImageRef] = []) async throws -> String? {
        var params: [String: JSONValue] = ["threadId": .string(threadId), "text": .string(text)]
        if !images.isEmpty { params["images"] = .array(images.map(\.jsonValue)) }
        return try await call("threads.send", .object(params), as: TurnResult.self).turnId
    }

    /// Draws an image panel (the Simulator's screenshot) or fills a list
    /// panel. Slow: it waits for simctl or the patch's function (20 s at
    /// most).
    func renderPanel(threadId: String, panelId: String) async throws -> PanelRender {
        try await call("panels.render", .object(["threadId": .string(threadId), "panelId": .string(panelId)]), as: PanelRender.self, timeout: .seconds(30))
    }

    /// What the thread has made, shared and pinned (docs/protocol.md,
    /// "Highlights"). A runner from before highlights answers `-32601`.
    func threadHighlights(threadId: String) async throws -> ThreadHighlights {
        try await call("threads.highlights", .object(["threadId": .string(threadId)]), as: ThreadHighlights.self)
    }

    /// Takes one off the list for good: a later mention doesn't bring it back.
    func removeHighlight(threadId: String, highlightId: String) async throws -> ThreadSummary {
        try await call("threads.removeHighlight", .object(["threadId": .string(threadId), "highlightId": .string(highlightId)]), as: ThreadResult.self).thread
    }

    /// Runs an action from the thread's patches. A command action answers
    /// when the command has finished (the runner stops it after 10 minutes).
    func runAction(threadId: String, actionId: String) async throws -> ActionRunResult {
        try await call("actions.run", .object(["threadId": .string(threadId), "actionId": .string(actionId)]), as: ActionRunResult.self, timeout: .seconds(11 * 60))
    }

    func interrupt(threadId: String) async throws {
        _ = try await call("threads.interrupt", .object(["threadId": .string(threadId)]), as: EmptyResult.self)
    }

    func updateThread(_ threadId: String, _ update: ThreadUpdate) async throws -> ThreadSummary {
        var params = update.params
        params["threadId"] = .string(threadId)
        return try await call("threads.update", .object(params), as: ThreadResult.self).thread
    }

    func events(threadId: String, afterSeq: Int? = nil, beforeSeq: Int? = nil, limit: Int? = nil) async throws -> EventsPage {
        var params: [String: JSONValue] = ["threadId": .string(threadId)]
        if let afterSeq { params["afterSeq"] = .number(Double(afterSeq)) }
        if let beforeSeq { params["beforeSeq"] = .number(Double(beforeSeq)) }
        if let limit { params["limit"] = .number(Double(limit)) }
        return try await call("threads.events", .object(params), as: EventsPage.self, timeout: .seconds(60))
    }

    func subscribe(threadId: String, afterSeq: Int? = nil) async throws -> SubscribeResult {
        var params: [String: JSONValue] = ["threadId": .string(threadId)]
        if let afterSeq { params["afterSeq"] = .number(Double(afterSeq)) }
        return try await call("threads.subscribe", .object(params), as: SubscribeResult.self, timeout: .seconds(60))
    }

    /// What a sub-agent has done so far, from the CLI's own record of it.
    /// `-32006` when there's no record.
    func subagent(threadId: String, subagentId: String) async throws -> SubagentTranscript {
        try await call("threads.subagent", .object(["threadId": .string(threadId), "subagentId": .string(subagentId)]), as: SubagentTranscript.self, timeout: .seconds(30))
    }

    func unsubscribe(threadId: String) async throws {
        _ = try await call("threads.unsubscribe", .object(["threadId": .string(threadId)]), as: EmptyResult.self)
    }

    func markSeen(threadId: String, seq: Int) async throws -> ThreadSummary {
        try await call("threads.markSeen", .object(["threadId": .string(threadId), "seq": .number(Double(seq))]), as: ThreadResult.self).thread
    }

    func respond(threadId: String, approvalId: String, decision: ApprovalDecision, message: String? = nil, answers: [String: String]? = nil) async throws {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "approvalId": .string(approvalId),
            "decision": .string(decision.rawValue),
        ]
        if let message { params["message"] = .string(message) }
        if let answers { params["answers"] = .object(answers.mapValues { .string($0) }) }
        _ = try await call("approvals.respond", .object(params), as: EmptyResult.self)
    }

    func importMedia(path: String) async throws -> ImageRef {
        try await call("media.import", .object(["path": .string(path)]), as: MediaImportResult.self).image
    }
}

// MARK: CLIs (docs/protocol.md, "CLI requests")

/// Each CLI request returns at once with the state when it arrived; the
/// progress of a check or an update comes through `clis.updated`. A runner
/// older than step 4 answers `-32601`, which callers read as "no CLI info"
/// rather than an error.
public extension RPCClient {
    func listClis() async throws -> [CliStatus] {
        try await call("clis.list", .object([:]), as: ClisResult.self).clis
    }

    /// Starts a check now; nil checks both.
    func checkClis(provider: String? = nil) async throws -> [CliStatus] {
        var params: [String: JSONValue] = [:]
        if let provider { params["provider"] = .string(provider) }
        return try await call("clis.check", .object(params), as: ClisResult.self).clis
    }

    /// Starts an update. `version` picks a kept Codex version (this is
    /// "Go back"); `force` installs past a hold ("Update anyway").
    func updateCli(provider: String, version: String? = nil, force: Bool = false) async throws -> [CliStatus] {
        var params: [String: JSONValue] = ["provider": .string(provider)]
        if let version { params["version"] = .string(version) }
        if force { params["force"] = .bool(true) }
        return try await call("clis.update", .object(params), as: ClisResult.self).clis
    }

    /// "auto", "notify" or "off".
    func setCliPolicy(provider: String, policy: String) async throws -> [CliStatus] {
        try await call("clis.setPolicy", .object(["provider": .string(provider), "policy": .string(policy)]), as: ClisResult.self).clis
    }
}

public struct ClisResult: Sendable, Decodable {
    public var clis: [CliStatus]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clis = c.lossyArray(CliStatus.self, forKey: .clis)
    }

    enum CodingKeys: String, CodingKey { case clis }
}

public enum ThreadListScope: String, Sendable, CaseIterable {
    case inbox, snoozed, archived
}

public struct NewThreadRequest: Sendable, Hashable {
    public var text: String
    public var images: [ImageRef]
    public var cwd: String?
    public var accountId: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var title: String?

    public init(text: String, images: [ImageRef] = [], cwd: String? = nil, accountId: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, title: String? = nil) {
        self.text = text
        self.images = images
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.title = title
    }
}

/// Fields for `threads.update`. A nil property is left out; the double
/// optionals send an explicit `null` to clear a value.
public struct ThreadUpdate: Sendable, Hashable {
    public var title: String?
    public var cwd: String?
    public var accountId: String?
    public var model: String??
    public var effort: String??
    public var permissionMode: PermissionMode?
    public var snoozedUntil: Date??
    /// Hibernate until the runner next starts (`snoozedUntil: "restart"`).
    /// Wins over `snoozedUntil`.
    public var snoozeUntilRestart: Bool
    public var archived: Bool?

    public init(title: String? = nil, cwd: String? = nil, accountId: String? = nil, model: String?? = nil, effort: String?? = nil, permissionMode: PermissionMode? = nil, snoozedUntil: Date?? = nil, snoozeUntilRestart: Bool = false, archived: Bool? = nil) {
        self.title = title
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.snoozedUntil = snoozedUntil
        self.snoozeUntilRestart = snoozeUntilRestart
        self.archived = archived
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let title { params["title"] = .string(title) }
        if let cwd { params["cwd"] = .string(cwd) }
        if let accountId { params["accountId"] = .string(accountId) }
        if let model { params["model"] = model.map { .string($0) } ?? .null }
        if let effort { params["effort"] = effort.map { .string($0) } ?? .null }
        if let permissionMode { params["permissionMode"] = .string(permissionMode.rawValue) }
        if snoozeUntilRestart {
            params["snoozedUntil"] = .string("restart")
        } else if let snoozedUntil {
            params["snoozedUntil"] = snoozedUntil.map { .string(ISO8601.format($0)) } ?? .null
        }
        if let archived { params["archived"] = .bool(archived) }
        return params
    }
}

public struct ThreadsResult: Sendable, Decodable {
    public var threads: [ThreadSummary]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decodeIfPresent(LossyArray<ThreadSummary>.self, forKey: .threads)?.elements ?? []
    }

    enum CodingKeys: String, CodingKey { case threads }
}

public struct ThreadResult: Sendable, Decodable {
    public var thread: ThreadSummary
}

public struct TurnResult: Sendable, Decodable {
    public var turnId: String?
}

public struct SubscribeResult: Sendable, Decodable {
    public var events: [Event]
    /// Text streamed so far for items still streaming (an older runner
    /// leaves it out).
    public var inProgress: [EventsPage.InProgress]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent(LossyArray<Event>.self, forKey: .events)?.elements ?? []
        inProgress = c.lossyArray(EventsPage.InProgress.self, forKey: .inProgress)
    }

    enum CodingKeys: String, CodingKey { case events, inProgress }
}

public struct MediaImportResult: Sendable, Decodable {
    public var image: ImageRef
}

extension ImageRef {
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["path": .string(path), "mediaType": .string(mediaType)]
        if let width { object["width"] = .number(Double(width)) }
        if let height { object["height"] = .number(Double(height)) }
        return .object(object)
    }
}

// MARK: Schedules (docs/protocol.md, "Schedules")

public extension RPCClient {
    func listSchedules(threadId: String? = nil) async throws -> [Schedule] {
        var params: [String: JSONValue] = [:]
        if let threadId { params["threadId"] = .string(threadId) }
        return try await call("schedules.list", .object(params), as: SchedulesResult.self).schedules
    }

    func createSchedule(_ request: NewScheduleRequest) async throws -> Schedule {
        try await call("schedules.create", .object(request.params), as: ScheduleResult.self).schedule
    }

    func updateSchedule(_ scheduleId: String, _ update: ScheduleUpdate) async throws -> Schedule {
        var params = update.params
        params["scheduleId"] = .string(scheduleId)
        return try await call("schedules.update", .object(params), as: ScheduleResult.self).schedule
    }

    func deleteSchedule(_ scheduleId: String) async throws {
        _ = try await call("schedules.delete", .object(["scheduleId": .string(scheduleId)]), as: EmptyResult.self)
    }

    /// Runs it now, as if it were due, even when paused.
    func runSchedule(_ scheduleId: String) async throws -> ScheduleRunResult {
        try await call("schedules.run", .object(["scheduleId": .string(scheduleId)]), as: ScheduleRunResult.self)
    }

    /// What a cron or time means and when it would next run, for the
    /// editor to show as Mike types. A cron it can't read is `-32602`.
    func previewSchedule(_ when: ScheduleWhen, timezone: String? = nil, count: Int = 3) async throws -> SchedulePreview {
        var params = when.params
        if let timezone { params["timezone"] = .string(timezone) }
        params["count"] = .number(Double(count))
        return try await call("schedules.preview", .object(params), as: SchedulePreview.self)
    }
}

/// When a schedule runs: once, or on a cron.
public enum ScheduleWhen: Sendable, Hashable {
    case at(Date)
    case cron(String)

    public var params: [String: JSONValue] {
        switch self {
        case .at(let date): return ["at": .string(ISO8601.format(date))]
        case .cron(let cron): return ["cron": .string(cron)]
        }
    }
}

public struct NewScheduleRequest: Sendable, Hashable {
    public var text: String
    public var title: String?
    public var when: ScheduleWhen
    /// Sends here; nil starts a new thread each time with the settings below.
    public var threadId: String?
    public var cwd: String?
    public var accountId: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?

    public init(text: String, title: String? = nil, when: ScheduleWhen, threadId: String? = nil, cwd: String? = nil,
                accountId: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil) {
        self.text = text
        self.title = title
        self.when = when
        self.threadId = threadId
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
    }

    public var params: [String: JSONValue] {
        var params = when.params
        params["text"] = .string(text)
        if let title { params["title"] = .string(title) }
        if let threadId {
            params["threadId"] = .string(threadId)
        } else {
            // New-thread settings only mean something without a thread.
            if let cwd { params["cwd"] = .string(cwd) }
            if let accountId { params["accountId"] = .string(accountId) }
            if let model { params["model"] = .string(model) }
            if let effort { params["effort"] = .string(effort) }
            if let permissionMode { params["permissionMode"] = .string(permissionMode.rawValue) }
        }
        return params
    }
}

/// Fields for `schedules.update`; nil ones are left out. The target thread
/// can't change (the runner says to make a new schedule).
public struct ScheduleUpdate: Sendable, Hashable {
    public var title: String?
    public var text: String?
    public var when: ScheduleWhen?
    public var paused: Bool?
    public var cwd: String?

    public init(title: String? = nil, text: String? = nil, when: ScheduleWhen? = nil, paused: Bool? = nil, cwd: String? = nil) {
        self.title = title
        self.text = text
        self.when = when
        self.paused = paused
        self.cwd = cwd
    }

    public var params: [String: JSONValue] {
        var params = when?.params ?? [:]
        if let title { params["title"] = .string(title) }
        if let text { params["text"] = .string(text) }
        if let paused { params["paused"] = .bool(paused) }
        if let cwd { params["cwd"] = .string(cwd) }
        return params
    }
}

public struct SchedulesResult: Sendable, Decodable {
    public var schedules: [Schedule]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedules = c.lossyArray(Schedule.self, forKey: .schedules)
    }

    enum CodingKeys: String, CodingKey { case schedules }
}

public struct ScheduleResult: Sendable, Decodable {
    public var schedule: Schedule
}

public struct ScheduleRunResult: Sendable, Decodable {
    public var schedule: Schedule
    public var threadId: String?
    public var turnId: String?
}

// MARK: Projects and the librarian (docs/protocol.md, "Projects")

/// A runner from before projects answers these with `-32601`, which callers
/// read as "no projects here" and hide them.
public extension RPCClient {
    /// Newest activity first; archived ones only (all of them) with `archived`.
    func listProjects(archived: Bool = false) async throws -> [Project] {
        var params: [String: JSONValue] = [:]
        if archived { params["archived"] = .bool(true) }
        return try await call("projects.list", .object(params), as: ProjectsResult.self).projects
    }

    func getProject(_ projectId: String) async throws -> ProjectGetResult {
        try await call("projects.get", .object(["projectId": .string(projectId)]), as: ProjectGetResult.self)
    }

    func createProject(_ request: NewProjectRequest) async throws -> Project {
        try await call("projects.create", .object(request.params), as: ProjectResult.self).project
    }

    func updateProject(_ projectId: String, _ update: ProjectUpdate) async throws -> Project {
        var params = update.params
        params["projectId"] = .string(projectId)
        return try await call("projects.update", .object(params), as: ProjectResult.self).project
    }

    /// Moves `projectId`'s folders and threads into `intoId` and deletes it.
    func mergeProject(_ projectId: String, into intoId: String) async throws -> Project {
        try await call("projects.merge", .object(["projectId": .string(projectId), "intoId": .string(intoId)]), as: ProjectResult.self).project
    }

    func deleteProject(_ projectId: String) async throws {
        _ = try await call("projects.delete", .object(["projectId": .string(projectId)]), as: EmptyResult.self)
    }

    /// What Mike does by hand: an added project is pinned, a removed one is
    /// never put back by the librarian.
    func setThreadProjects(_ threadId: String, add: [String] = [], remove: [String] = []) async throws -> ThreadSummary {
        try await call("threads.setProjects", .object(SetProjectsRequest(threadId: threadId, add: add, remove: remove).params), as: ThreadResult.self).thread
    }

    func librarianStatus() async throws -> LibrarianStatus {
        try await call("librarian.status", .object([:]), as: LibrarianResult.self).librarian
    }

    /// A look at one thread now, or with none a backfill over every thread
    /// it has never looked at.
    func runLibrarian(threadId: String? = nil) async throws -> LibrarianStatus {
        var params: [String: JSONValue] = [:]
        if let threadId { params["threadId"] = .string(threadId) }
        return try await call("librarian.run", .object(params), as: LibrarianResult.self).librarian
    }

    func updateLibrarian(paused: Bool) async throws -> LibrarianStatus {
        try await call("librarian.update", .object(["paused": .bool(paused)]), as: LibrarianResult.self).librarian
    }
}

public struct NewProjectRequest: Sendable, Hashable {
    public var title: String
    public var folders: [String]
    public var goals: String?
    public var threadIds: [String]

    public init(title: String, folders: [String] = [], goals: String? = nil, threadIds: [String] = []) {
        self.title = title
        self.folders = folders
        self.goals = goals
        self.threadIds = threadIds
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = ["title": .string(title)]
        if !folders.isEmpty { params["folders"] = .array(folders.map { .string($0) }) }
        if let goals { params["goals"] = .string(goals) }
        if !threadIds.isEmpty { params["threadIds"] = .array(threadIds.map { .string($0) }) }
        return params
    }
}

/// Fields for `projects.update`; nil ones are left out, and what's given
/// replaces what was there.
public struct ProjectUpdate: Sendable, Hashable {
    public var title: String?
    public var folders: [String]?
    public var goals: String?
    public var state: String?
    public var notes: String?
    public var archived: Bool?

    public init(title: String? = nil, folders: [String]? = nil, goals: String? = nil, state: String? = nil, notes: String? = nil, archived: Bool? = nil) {
        self.title = title
        self.folders = folders
        self.goals = goals
        self.state = state
        self.notes = notes
        self.archived = archived
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let title { params["title"] = .string(title) }
        if let folders { params["folders"] = .array(folders.map { .string($0) }) }
        if let goals { params["goals"] = .string(goals) }
        if let state { params["state"] = .string(state) }
        if let notes { params["notes"] = .string(notes) }
        if let archived { params["archived"] = .bool(archived) }
        return params
    }
}

public struct SetProjectsRequest: Sendable, Hashable {
    public var threadId: String
    public var add: [String]
    public var remove: [String]

    public init(threadId: String, add: [String] = [], remove: [String] = []) {
        self.threadId = threadId
        self.add = add
        self.remove = remove
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = ["threadId": .string(threadId)]
        if !add.isEmpty { params["add"] = .array(add.map { .string($0) }) }
        if !remove.isEmpty { params["remove"] = .array(remove.map { .string($0) }) }
        return params
    }
}

public struct ProjectsResult: Sendable, Decodable {
    public var projects: [Project]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = c.lossyArray(Project.self, forKey: .projects)
    }

    enum CodingKeys: String, CodingKey { case projects }
}

public struct ProjectResult: Sendable, Decodable {
    public var project: Project
}

public struct ProjectGetResult: Sendable, Decodable {
    public var project: Project
    /// Its threads, newest activity first, put away ones included.
    public var threadIds: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(Project.self, forKey: .project)
        threadIds = c.lossyArray(String.self, forKey: .threadIds)
    }

    enum CodingKeys: String, CodingKey { case project, threadIds }
}

public struct LibrarianResult: Sendable, Decodable {
    public var librarian: LibrarianStatus
}
