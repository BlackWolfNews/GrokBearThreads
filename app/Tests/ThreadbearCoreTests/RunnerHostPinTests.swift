import Foundation
import XCTest
@testable import ThreadbearCore

/// A runner's token goes only to the host it was first sent to
/// (docs/protocol.md, "Other runners' threads"): the backend's mirror says
/// where a runner is, and anyone with the shared runner key can rewrite it.
final class RunnerHostPinTests: XCTestCase {
    func testDecision() {
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: "bruce.tail9ef766.ts.net"), .send)
        XCTAssertEqual(RunnerHostPin.decide(host: "Bruce.Tail9ef766.ts.net.", pinned: "bruce.tail9ef766.ts.net"), .send,
                       "case and a trailing dot are the same host")
        XCTAssertEqual(RunnerHostPin.decide(host: "evil.example.com", pinned: "bruce.tail9ef766.ts.net"),
                       .refuse(pinned: "bruce.tail9ef766.ts.net", seen: "evil.example.com"))
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: nil), .pin("bruce.tail9ef766.ts.net"),
                       "nothing pinned yet (a token copied in before pins): the first host is trusted")
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: "  "), .pin("bruce.tail9ef766.ts.net"))
    }

    func testPinFileSitsBesideTheToken() {
        XCTAssertEqual(RunnerHostPin.file(forToken: "/h/secrets/runners/cb921b2447ea.token"), "/h/secrets/runners/cb921b2447ea.host")
        XCTAssertEqual(RunnerHostPin.file(forToken: "/h/odd"), "/h/odd.host")
    }

    func testFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = dir.appendingPathComponent("r.token").path
        XCTAssertNil(RunnerHostPins.files.read(token))
        XCTAssertTrue(RunnerHostPins.files.write(token, "bruce.tail9ef766.ts.net"))
        XCTAssertEqual(RunnerHostPins.files.read(token), "bruce.tail9ef766.ts.net")
        let mode = try FileManager.default.attributesOfItem(atPath: RunnerHostPin.file(forToken: token))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    private final class Dialled: @unchecked Sendable { var urls: [URL] = [] }

    @MainActor
    func testClientsPinThenRefuseAnotherHost() async throws {
        let dialled = Dialled()
        let pins = RunnerHostPins.memory()
        let remote = RemoteClients(version: "test", makeTransport: { url, _ in
            dialled.urls.append(url)
            let transport = FakeTransport()
            transport.onSend = { request in
                [E.json(["jsonrpc": "2.0", "id": request["id"]!, "result": ["runnerVersion": "0.1.0", "protocol": 1]])]
            }
            return transport
        }, readToken: { _ in "secret" }, pins: pins)
        var logged: [String] = []
        remote.onLog = { logged.append($0) }

        let home = URL(string: "wss://bruce.tail9ef766.ts.net:8798/rpc")!
        var bruce = RemoteRunner(id: "r_bruce", name: "bruce", online: true, rpcUrl: home, tokenFile: "/t/r_bruce.token")
        _ = try await remote.client(for: bruce)
        XCTAssertEqual(pins.read("/t/r_bruce.token"), "bruce.tail9ef766.ts.net", "pinned on first use")
        remote.close("r_bruce")

        // Same host, another port: still that Mac.
        bruce.rpcUrl = URL(string: "wss://bruce.tail9ef766.ts.net:9000/rpc")!
        _ = try await remote.client(for: bruce)
        remote.close("r_bruce")
        XCTAssertEqual(dialled.urls.count, 2)

        bruce.rpcUrl = URL(string: "wss://evil.example.com/rpc")!
        do {
            _ = try await remote.client(for: bruce)
            XCTFail("expected a refusal")
        } catch let error as RemoteUnreachable {
            XCTAssertEqual(error.reason, .hostChanged(pinned: "bruce.tail9ef766.ts.net", seen: "evil.example.com"))
            XCTAssertTrue(error.detail.contains("evil.example.com"))
            XCTAssertTrue(error.detail.contains("secrets/runners/r_bruce.host"), "says how to accept a real move")
            XCTAssertFalse(error.detail.contains("—"), "no em dashes in UI copy")
        }
        XCTAssertEqual(dialled.urls.count, 2, "the token never went to the new host")
        XCTAssertEqual(pins.read("/t/r_bruce.token"), "bruce.tail9ef766.ts.net", "a refusal doesn't move the pin")
        XCTAssertTrue(logged.contains { $0.contains("evil.example.com") }, "the app log says what was refused")
    }
}
