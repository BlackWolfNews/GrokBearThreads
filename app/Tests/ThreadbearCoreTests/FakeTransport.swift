import Foundation
import Synchronization
@testable import ThreadbearCore

/// In-memory transport: records what the client sends and lets a test (or an
/// `onSend` responder) push messages back.
final class FakeTransport: RPCTransport, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var inbox: [Data] = []
        var waiter: CheckedContinuation<Data, Error>?
        var closed = false
    }

    private let state = Mutex(State())
    var openError: RPCError?
    /// Called for each sent message; return replies to push back.
    var onSend: (@Sendable ([String: Any]) -> [String])?

    func open() async throws {
        if let openError { throw openError }
    }

    func send(_ text: String) async throws {
        let closed = state.withLock { state -> Bool in
            state.sent.append(text)
            return state.closed
        }
        if closed { throw RPCError.disconnected(nil) }
        if let onSend, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for reply in onSend(object) { push(reply) }
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.inbox.isEmpty {
                    continuation.resume(returning: state.inbox.removeFirst())
                } else if state.closed {
                    continuation.resume(throwing: RPCError.disconnected("closed"))
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    func close() {
        close(with: .disconnected("closed"))
    }

    /// Ends the connection as the runner would, e.g. with `.unauthorized`
    /// for a 4401 close.
    func close(with error: RPCError) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, Error>? in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: error)
    }

    func push(_ text: String) {
        let data = Data(text.utf8)
        let waiter = state.withLock { state -> CheckedContinuation<Data, Error>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbox.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    var sent: [[String: Any]] {
        state.withLock { $0.sent }.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Waits until the client has sent `count` messages.
    func waitForSent(_ count: Int) async {
        for _ in 0..<500 {
            if state.withLock({ $0.sent.count }) >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Builds event JSON objects for tests.
enum E {
    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func event(_ seq: Int, _ type: String, _ fields: [String: Any] = [:], turn: String? = "t1") -> Event {
        var object: [String: Any] = ["seq": seq, "ts": "2026-10-26T10:00:00Z", "threadId": "th1", "type": type]
        if let turn { object["turnId"] = turn }
        for (key, value) in fields { object[key] = value }
        return try! JSONDecoder().decode(Event.self, from: Data(json(object).utf8))
    }

    static func user(_ seq: Int, _ text: String) -> Event { event(seq, "user.message", ["text": text, "images": []]) }
    static func text(_ seq: Int, _ item: String, _ text: String) -> Event { event(seq, "assistant.text", ["itemId": item, "text": text]) }
    static func delta(_ seq: Int, _ item: String, _ text: String) -> Event { event(seq, "assistant.text.delta", ["itemId": item, "text": text]) }
    static func call(_ seq: Int, _ item: String, name: String = "Bash", kind: String = "command", title: String = "ls", input: [String: Any] = [:]) -> Event {
        event(seq, "tool.call", ["itemId": item, "name": name, "kind": kind, "title": title, "input": input])
    }
    static func result(_ seq: Int, _ item: String, ok: Bool = true, text: String = "done", images: [[String: Any]] = []) -> Event {
        event(seq, "tool.result", ["itemId": item, "ok": ok, "text": text, "truncated": false, "images": images])
    }
    static func done(_ seq: Int, turn: String = "t1") -> Event {
        event(seq, "turn.completed", ["turnId": turn, "outcome": "completed", "durationMs": 4200, "costUsd": 0.12], turn: turn)
    }
}
