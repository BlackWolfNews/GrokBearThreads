import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// Picking across providers, and the limit line after a switch.
@MainActor
final class AccountPickTests: XCTestCase {
    private let keys = [AppModel.lastModelKey, AppModel.lastEffortKey, AppModel.lastAccountKey, "lastModel.codex", "lastEffort.codex",
                        "lastAccountId.byProvider", "lastAccountId.codex.byProvider"]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func room(_ percent: Double, blocked: Bool = false) -> AccountUsage {
        AccountUsage(windows: [UsageWindow(kind: "five_hour", title: "5-hour", remainingPercent: percent),
                               UsageWindow(kind: "weekly", title: "Weekly", remainingPercent: 90)], blocked: blocked)
    }

    private var accounts: [Account] {
        [
            Account(id: "claude-main", title: "a@x", usage: room(40)),
            Account(id: "claude-2", title: "w@x", note: "Convex work only", usage: room(99)),
            Account(id: "claude-4", title: "d@x", usage: room(0, blocked: true)),
            Account(id: "claude-3", title: "c@x", usage: room(70)),
            Account(id: "codex-main", provider: "codex", title: "Codex · a@x",
                    models: [ModelChoice(id: "gpt-6.1-sol", model: "gpt-6.1-sol", title: "GPT-6.1-Sol")], usage: room(80)),
        ]
    }

    /// One `threads.update` with the account and the model together, and
    /// the model remembered under Codex, not under the Claude thread's.
    func testACodexPickOnAClaudeThreadIsOneUpdateRememberedUnderCodex() async throws {
        let app = AppModel()
        app.accounts = accounts
        let transport = RecordingTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        app.threads["th1"] = ThreadSummary(id: "th1", title: "t", accountId: "claude-main")
        app.remember(model: "sonnet", provider: "claude")
        app.remember(effort: "high", provider: "codex")
        let settings = ThreadSettings(app: app, thread: app.threads["th1"])
        guard let row = settings.rows(for: "codex").first(where: { $0.id == "gpt-6.1-sol" }) else { return XCTFail("no Codex row") }
        settings.pick(row, in: "codex")
        for _ in 0..<200 where transport.updates.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.updates.count, 1, "one call, so the account and the model can't cross")
        let params = transport.updates.first ?? [:]
        XCTAssertEqual(params["accountId"] as? String, "codex-main")
        XCTAssertEqual(params["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(params["effort"] as? String, "high", "Codex's remembered effort goes with it")
        XCTAssertEqual(app.lastModels["claude"], "sonnet", "the Claude default isn't touched")
        XCTAssertEqual(app.lastModels["codex"], "gpt-6.1-sol")
        XCTAssertEqual(AppModel().lastModels["claude"], "sonnet", "nor the saved one")
    }

    /// Another provider's column moves to its account with the most room,
    /// never a noted or blocked one while a better one exists.
    func testAnotherProvidersColumnPicksItsBestAccount() {
        let app = AppModel()
        app.accounts = accounts
        app.newThreadAccount = "codex-main"
        let settings = ThreadSettings(app: app, thread: nil)
        XCTAssertEqual(settings.listedAccount(for: "claude"), "claude-3", "not claude-main (first), claude-2 (noted) or claude-4 (blocked)")
        // A new thread picking from there moves to that account and keeps the
        // model under Claude.
        let row = settings.rows(for: "claude").first { $0.id == "opus" } ?? ModelPicker.Row(id: "opus", title: "Opus")
        settings.pick(row, in: "claude")
        XCTAssertEqual(app.newThreadAccount, "claude-3")
        XCTAssertEqual(app.lastModels["claude"], "opus")
        XCTAssertNil(app.lastModels["codex"])
        // With only noted and blocked accounts, the last one used there.
        app.accounts = accounts.filter { $0.id == "claude-2" || $0.id == "claude-4" || $0.provider == "codex" }
        app.rememberLastAccount("claude-4")
        XCTAssertEqual(app.accountForProvider("claude"), "claude-4")
    }

    /// The limit line names the account the turn failed on, and goes once
    /// the thread is on another one.
    func testTheLimitLineGoesAfterASwitch() {
        let app = AppModel()
        app.accounts = accounts
        var thread = ThreadSummary(id: "th1", title: "t", accountId: "claude-4", status: .error)
        app.threads["th1"] = thread
        XCTAssertEqual(app.failedOnAccount["th1"], "claude-4")
        // claude-4 is blocked: the line, offering claude-3.
        XCTAssertEqual(app.limitAdvice(for: thread)?.target?.id, "claude-3")
        thread.accountId = "claude-3"
        app.threads["th1"] = thread
        XCTAssertEqual(app.failedOnAccount["th1"], "claude-4", "still the account it failed on")
        XCTAssertNil(app.limitAdvice(for: thread), "the new account isn't the one that ran out")
        thread.status = .idle
        app.threads["th1"] = thread
        XCTAssertNil(app.failedOnAccount["th1"])
    }
}

/// Answers every call with an empty thread, and keeps `threads.update`'s params.
private final class RecordingTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var recorded: [[String: Any]] = []

    var updates: [[String: Any]] { lock.withLock { recorded } }

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        if method == "threads.update" { lock.withLock { recorded.append(object["params"] as? [String: Any] ?? [:]) } }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["thread": ["id": "th1", "title": "t"]]]
        push(try JSONSerialization.data(withJSONObject: reply))
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {}

    private func push(_ data: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }
}
