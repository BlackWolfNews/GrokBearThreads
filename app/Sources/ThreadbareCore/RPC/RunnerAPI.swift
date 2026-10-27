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

    /// Draws an image panel (the Simulator's screenshot). Slow: it waits
    /// for simctl.
    func renderPanel(threadId: String, panelId: String) async throws -> PanelRender {
        try await call("panels.render", .object(["threadId": .string(threadId), "panelId": .string(panelId)]), as: PanelRender.self, timeout: .seconds(30))
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
    public var archived: Bool?

    public init(title: String? = nil, cwd: String? = nil, accountId: String? = nil, model: String?? = nil, effort: String?? = nil, permissionMode: PermissionMode? = nil, snoozedUntil: Date?? = nil, archived: Bool? = nil) {
        self.title = title
        self.cwd = cwd
        self.accountId = accountId
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.snoozedUntil = snoozedUntil
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
        if let snoozedUntil { params["snoozedUntil"] = snoozedUntil.map { .string(ISO8601.format($0)) } ?? .null }
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
