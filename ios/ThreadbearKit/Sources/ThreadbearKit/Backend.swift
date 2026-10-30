import Foundation

/// What the app needs from Threadbear's Convex mirror (convex/phone.ts).
/// Reads are live; writes are commands the owning runner picks up and
/// applies, each returning a command id the app can watch.
public extension Backend {
    func send(threadId: String, text: String) async throws -> String {
        try await send(threadId: threadId, text: text, answers: [])
    }
}

public protocol Backend: Sendable {
    func me() async throws -> PhoneIdentity
    func runners() -> AsyncThrowingStream<[PhoneRunner], Error>
    /// Every runner's projects (not archived ones), with their icons from
    /// backend API 5, so a row can show its project the way the Mac does.
    func projects() -> AsyncThrowingStream<[PhoneProject], Error>
    func threads(_ view: ThreadsView) -> AsyncThrowingStream<[PhoneThread], Error>
    /// Nil once the thread's gone from the mirror.
    func thread(_ threadId: String) -> AsyncThrowingStream<ThreadDetail?, Error>
    func command(_ commandId: String) -> AsyncThrowingStream<CommandStatus?, Error>
    func connectionStates() -> AsyncStream<Bool>

    /// `answers` (backend API 14): the open card's asks the message answers.
    func send(threadId: String, text: String, answers: [AskAnswer]) async throws -> String
    func respond(threadId: String, approvalId: String, decision: ApprovalOption) async throws -> String
    /// Answers keyed by question text, several choices joined with ", ",
    /// as the Mac app sends them. `summary` goes in the transcript.
    func answer(threadId: String, approvalId: String, answers: [String: String], summary: String) async throws -> String
    func update(threadId: String, change: ThreadChange) async throws -> String
    func create(text: String, runnerId: String?, cwd: String?) async throws -> String
    /// A quick ask that's been answered (backend API 10): the runner makes it a thread with the
    /// question and its answer in, without running a turn, so a follow-up is an ordinary reply.
    /// The command's threadId is that thread.
    func quickAsk(_ ask: QuickAskRecord) async throws -> String
    /// The newest `limit` messages of a thread, tool lines included, live
    /// (backend API 2). Reads Convex alone, so it works while the Mac sleeps;
    /// more history is a bigger limit.
    func messages(_ threadId: String, limit: Int) -> AsyncThrowingStream<MessagePage, Error>
    /// For a backend before API 2: asks the runner for up to 50 text messages older than `beforeSeq`;
    /// they turn up in `thread(_:)` once it has written them.
    func loadEarlier(threadId: String, beforeSeq: Int) async throws -> String
    /// pushKey (backend API 4): base64 of this phone's relay key (PushKeyStore).
    func registerDevice(apnsToken: String, environment: String, pushKey: String?) async throws
    /// Backend API 3: when this phone (by its APNs token) is notified.
    func setNotifications(apnsToken: String, notify: NotifyMode) async throws
}

/// The real backend: convex/phone.ts, called with the phone token.
public final class ConvexBackend: Backend, @unchecked Sendable {
    private let transport: any ConvexTransport
    private let token: String

    public init(transport: any ConvexTransport, token: String) {
        self.transport = transport
        self.token = token
    }

    public convenience init(deploymentURL: URL, token: String) {
        self.init(transport: ConvexMobileTransport(deploymentURL: deploymentURL), token: token)
    }

    private func args(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        extra.merging(["token": .string(token)]) { $1 }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw TransportError.server("Couldn't read the server's answer: \(error)")
        }
    }

    /// A live query. For one that can say "not found" (`missing`), that
    /// error becomes the value instead, and the stream ends.
    private func live<T: Decodable & Sendable>(_ name: String, _ extra: [String: JSONValue], as: T.Type,
                                               missing: T? = nil) -> AsyncThrowingStream<T, Error> {
        let raw = transport.subscribe(name, args(extra))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in raw { continuation.yield(try Self.decode(T.self, data)) }
                    continuation.finish()
                } catch TransportError.notFound(let message) {
                    if let missing { continuation.yield(missing); continuation.finish() } else {
                        continuation.finish(throwing: TransportError.notFound(message))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func command(_ name: String, _ extra: [String: JSONValue]) async throws -> String {
        let data = try await transport.mutation(name, args(extra))
        // The mutation answers the command id as a bare string.
        return try Self.decode(String.self, data)
    }

    public func me() async throws -> PhoneIdentity {
        try Self.decode(PhoneIdentity.self, try await transport.query("phone:me", args()))
    }

    public func runners() -> AsyncThrowingStream<[PhoneRunner], Error> {
        live("phone:runners", [:], as: [PhoneRunner].self)
    }

    public func projects() -> AsyncThrowingStream<[PhoneProject], Error> {
        live("phone:projects", [:], as: [PhoneProject].self)
    }

    public func threads(_ view: ThreadsView) -> AsyncThrowingStream<[PhoneThread], Error> {
        live("phone:threads", ["view": .string(view.rawValue)], as: [PhoneThread].self)
    }

    public func thread(_ threadId: String) -> AsyncThrowingStream<ThreadDetail?, Error> {
        live("phone:thread", ["threadId": .string(threadId)], as: ThreadDetail?.self, missing: .some(nil))
    }

    public func messages(_ threadId: String, limit: Int) -> AsyncThrowingStream<MessagePage, Error> {
        live("phone:messages", ["threadId": .string(threadId), "limit": .number(Double(limit)), "tools": .bool(true)], as: MessagePage.self)
    }

    public func command(_ commandId: String) -> AsyncThrowingStream<CommandStatus?, Error> {
        live("phone:command", ["commandId": .string(commandId)], as: CommandStatus?.self, missing: .some(nil))
    }

    public func connectionStates() -> AsyncStream<Bool> { transport.connectionStates() }

    public func send(threadId: String, text: String, answers: [AskAnswer]) async throws -> String {
        var args: [String: JSONValue] = ["threadId": .string(threadId), "text": .string(text)]
        // Only when there are some: a backend before API 14 refuses the field.
        if !answers.isEmpty {
            args["answers"] = .array(answers.map { .object(["action": .string($0.action), "answer": .string($0.answer)]) })
        }
        return try await command("phone:send", args)
    }

    public func respond(threadId: String, approvalId: String, decision: ApprovalOption) async throws -> String {
        try await command("phone:respond", [
            "threadId": .string(threadId), "approvalId": .string(approvalId), "decision": .string(decision.rawValue),
        ])
    }

    public func answer(threadId: String, approvalId: String, answers: [String: String], summary: String) async throws -> String {
        try await command("phone:answer", [
            "threadId": .string(threadId), "approvalId": .string(approvalId),
            "answers": .object(answers.mapValues { .string($0) }), "message": .string(summary),
        ])
    }

    public func update(threadId: String, change: ThreadChange) async throws -> String {
        try await command("phone:update", ["threadId": .string(threadId), "change": change.json])
    }

    public func create(text: String, runnerId: String?, cwd: String?) async throws -> String {
        var extra: [String: JSONValue] = ["text": .string(text)]
        if let runnerId { extra["runnerId"] = .string(runnerId) }
        if let cwd { extra["cwd"] = .string(cwd) }
        return try await command("phone:create", extra)
    }

    public func quickAsk(_ ask: QuickAskRecord) async throws -> String {
        var extra: [String: JSONValue] = [
            "question": .string(ask.question), "answer": .string(ask.answer),
            "askedAt": .number(ask.askedAt.timeIntervalSince1970 * 1000),
        ]
        if !ask.sources.isEmpty {
            extra["sources"] = .array(ask.sources.map { .object(["title": .string($0.title), "url": .string($0.url)]) })
        }
        return try await command("phone:quickAsk", extra)
    }

    public func loadEarlier(threadId: String, beforeSeq: Int) async throws -> String {
        try await command("phone:loadEarlier", ["threadId": .string(threadId), "beforeSeq": .number(Double(beforeSeq))])
    }

    public func registerDevice(apnsToken: String, environment: String, pushKey: String?) async throws {
        var extra: [String: JSONValue] = ["apnsToken": .string(apnsToken), "environment": .string(environment)]
        if let pushKey { extra["pushKey"] = .string(pushKey) }
        _ = try await transport.mutation("phone:registerDevice", args(extra))
    }

    public func setNotifications(apnsToken: String, notify: NotifyMode) async throws {
        _ = try await transport.mutation("phone:setNotifications", args([
            "apnsToken": .string(apnsToken), "notify": .string(notify.rawValue),
        ]))
    }
}

/// A spoken question and the answer the archive server gave, for `Backend.quickAsk`. Clipped to
/// what phone:quickAsk takes.
public struct QuickAskRecord: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public var title: String
        public var url: String
        public init(title: String, url: String) { self.title = title; self.url = url }
    }

    public var question: String
    public var answer: String
    public var sources: [Source]
    public var askedAt: Date

    public init(question: String, answer: String, sources: [Source], askedAt: Date) {
        self.question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        self.answer = String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000))
        self.sources = Array(sources.filter { !$0.url.isEmpty }.prefix(10))
        self.askedAt = askedAt
    }

    /// Worth keeping: there's a question and some answer.
    public var isWorthKeeping: Bool { !question.isEmpty && !answer.isEmpty }
}

/// The answers map for a question card, as the Mac app builds it
/// (Cells.swift): chosen labels per question, joined with ", "; typed text
/// replaces a single choice on the last question and is added to a
/// multiple one.
public enum Answers {
    public static func build(_ questions: [Question], chosen: [Int: Set<String>], typed: String) -> [String: String] {
        var answers: [String: String] = [:]
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = questions.count - 1
        for (index, question) in questions.enumerated() {
            var parts = question.options.map(\.label).filter { chosen[index]?.contains($0) == true }
            if !typed.isEmpty, index == last {
                if question.multiSelect { parts.append(typed) } else { parts = [typed] }
            }
            if !parts.isEmpty { answers[question.question] = parts.joined(separator: ", ") }
        }
        return answers
    }

    /// One line for the transcript: "Which database? Convex · Tests? Yes".
    public static func summary(_ questions: [Question], answers: [String: String]) -> String {
        questions.compactMap { q in answers[q.question].map { questions.count == 1 ? $0 : "\(q.header ?? q.question) \($0)" } }
            .joined(separator: " · ")
    }
}
