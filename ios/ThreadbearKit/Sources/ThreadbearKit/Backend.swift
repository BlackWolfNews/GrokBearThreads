import Foundation

/// What the app needs from Threadbear's Convex mirror (convex/phone.ts).
/// Reads are live; writes are commands the owning runner picks up and
/// applies, each returning a command id the app can watch.
public protocol Backend: Sendable {
    func me() async throws -> PhoneIdentity
    func runners() -> AsyncThrowingStream<[PhoneRunner], Error>
    func threads(_ view: ThreadsView) -> AsyncThrowingStream<[PhoneThread], Error>
    /// Nil once the thread's gone from the mirror.
    func thread(_ threadId: String) -> AsyncThrowingStream<ThreadDetail?, Error>
    func command(_ commandId: String) -> AsyncThrowingStream<CommandStatus?, Error>
    func connectionStates() -> AsyncStream<Bool>

    func send(threadId: String, text: String) async throws -> String
    func respond(threadId: String, approvalId: String, decision: ApprovalOption) async throws -> String
    /// Answers keyed by question text, several choices joined with ", ",
    /// as the Mac app sends them. `summary` goes in the transcript.
    func answer(threadId: String, approvalId: String, answers: [String: String], summary: String) async throws -> String
    func update(threadId: String, change: ThreadChange) async throws -> String
    func create(text: String, runnerId: String?, cwd: String?) async throws -> String
    /// The newest `limit` messages of a thread, tool lines included, live
    /// (backend API 2). Reads Convex alone, so it works while the Mac sleeps;
    /// more history is a bigger limit.
    func messages(_ threadId: String, limit: Int) -> AsyncThrowingStream<MessagePage, Error>
    /// For a backend before API 2: asks the runner for up to 50 text messages older than `beforeSeq`;
    /// they turn up in `thread(_:)` once it has written them.
    func loadEarlier(threadId: String, beforeSeq: Int) async throws -> String
    func registerDevice(apnsToken: String, environment: String) async throws
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

    public func send(threadId: String, text: String) async throws -> String {
        try await command("phone:send", ["threadId": .string(threadId), "text": .string(text)])
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

    public func loadEarlier(threadId: String, beforeSeq: Int) async throws -> String {
        try await command("phone:loadEarlier", ["threadId": .string(threadId), "beforeSeq": .number(Double(beforeSeq))])
    }

    public func registerDevice(apnsToken: String, environment: String) async throws {
        _ = try await transport.mutation("phone:registerDevice", args([
            "apnsToken": .string(apnsToken), "environment": .string(environment),
        ]))
    }

    public func setNotifications(apnsToken: String, notify: NotifyMode) async throws {
        _ = try await transport.mutation("phone:setNotifications", args([
            "apnsToken": .string(apnsToken), "notify": .string(notify.rawValue),
        ]))
    }
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
