import Foundation
import XCTest
@testable import ThreadbearCore

/// A runner's token goes only to the host written beside it
/// (docs/protocol.md, "Other runners' threads"): the backend's mirror says
/// where a runner is, and anyone with the shared runner key can rewrite it,
/// so the mirror's host is never trusted on its own, not even the first time.
final class RunnerHostPinTests: XCTestCase {
    func testDecision() {
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: "bruce.tail9ef766.ts.net"), .send)
        XCTAssertEqual(RunnerHostPin.decide(host: "Bruce.Tail9ef766.ts.net.", pinned: "bruce.tail9ef766.ts.net"), .send,
                       "case and a trailing dot are the same host")
        XCTAssertEqual(RunnerHostPin.decide(host: "evil.example.com", pinned: "bruce.tail9ef766.ts.net"),
                       .refuse(pinned: "bruce.tail9ef766.ts.net", seen: "evil.example.com"))
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: nil), .noPin,
                       "nothing pinned: no trust on first use from the mirror")
        XCTAssertEqual(RunnerHostPin.decide(host: "bruce.tail9ef766.ts.net", pinned: "  "), .noPin)
    }

    func testPinFileSitsBesideTheToken() {
        XCTAssertEqual(RunnerHostPin.file(forToken: "/h/secrets/runners/cb921b2447ea.token"), "/h/secrets/runners/cb921b2447ea.host")
        XCTAssertEqual(RunnerHostPin.file(forToken: "/h/odd"), "/h/odd.host")
    }

    func testFilesAreRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = dir.appendingPathComponent("r.token").path
        XCTAssertNil(RunnerHostPins.files.read(token))
        try "bruce.tail9ef766.ts.net\n".write(toFile: RunnerHostPin.file(forToken: token), atomically: true, encoding: .utf8)
        XCTAssertEqual(RunnerHostPins.files.read(token), "bruce.tail9ef766.ts.net")
    }

    private final class Dialled: @unchecked Sendable { var urls: [URL] = [] }

    @MainActor
    private func clients(_ pins: RunnerHostPins, _ dialled: Dialled) -> RemoteClients {
        RemoteClients(version: "test", makeTransport: { url, _ in
            dialled.urls.append(url)
            let transport = FakeTransport()
            transport.onSend = { request in
                [E.json(["jsonrpc": "2.0", "id": request["id"]!, "result": ["runnerVersion": "0.1.0", "protocol": 1]])]
            }
            return transport
        }, readToken: { _ in "secret" }, pins: pins)
    }

    private let home = URL(string: "wss://bruce.tail9ef766.ts.net:8798/rpc")!

    @MainActor
    func testMissingPinIsRefused() async {
        let dialled = Dialled()
        let remote = clients(.memory(), dialled)
        var logged: [String] = []
        remote.onLog = { logged.append($0) }
        let bruce = RemoteRunner(id: "r_bruce", name: "bruce", online: true, rpcUrl: home, tokenFile: "/t/r_bruce.token")
        do {
            _ = try await remote.client(for: bruce)
            XCTFail("expected a refusal")
        } catch let error as RemoteUnreachable {
            XCTAssertEqual(error.reason, .noHostPin(file: "/t/r_bruce.host"))
            XCTAssertTrue(error.detail.contains("/t/r_bruce.host"), "names the file to make")
            XCTAssertTrue(error.detail.contains("tb pair"), "says how to get the line")
            XCTAssertFalse(error.detail.contains("bruce.tail9ef766.ts.net"), "never suggests the mirror's host")
            XCTAssertFalse(error.detail.contains("—"), "no em dashes in UI copy")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(dialled.urls, [], "the token went nowhere")
        XCTAssertTrue(logged.contains { $0.contains("r_bruce") }, "the app log says what was refused")
    }

    @MainActor
    func testUnreadablePinIsRefused() async throws {
        // A real .host file the app can't read (as if the disk or its
        // permissions failed): refused, not treated as permission to send.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("r_bruce.host").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let token = dir.appendingPathComponent("r_bruce.token").path
        let pin = RunnerHostPin.file(forToken: token)
        try "bruce.tail9ef766.ts.net\n".write(toFile: pin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pin)
        let dialled = Dialled()
        let remote = clients(.files, dialled)
        let bruce = RemoteRunner(id: "r_bruce", name: "bruce", online: true, rpcUrl: home, tokenFile: token)
        do {
            _ = try await remote.client(for: bruce)
            XCTFail("expected a refusal")
        } catch let error as RemoteUnreachable {
            XCTAssertEqual(error.reason, .noHostPin(file: pin))
        }
        XCTAssertEqual(dialled.urls, [])
    }

    @MainActor
    func testMatchingPinSendsAndAnotherHostIsRefused() async throws {
        let dialled = Dialled()
        let pins = RunnerHostPins.memory(["/t/r_bruce.token": "bruce.tail9ef766.ts.net"])
        let remote = clients(pins, dialled)
        var logged: [String] = []
        remote.onLog = { logged.append($0) }

        var bruce = RemoteRunner(id: "r_bruce", name: "bruce", online: true, rpcUrl: home, tokenFile: "/t/r_bruce.token")
        _ = try await remote.client(for: bruce)
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
            XCTAssertTrue(error.detail.contains("tb pair"))
            XCTAssertFalse(error.detail.contains("—"), "no em dashes in UI copy")
        }
        XCTAssertEqual(dialled.urls.count, 2, "the token never went to the new host")
        XCTAssertEqual(pins.read("/t/r_bruce.token"), "bruce.tail9ef766.ts.net", "a refusal doesn't move the pin")
        XCTAssertTrue(logged.contains { $0.contains("evil.example.com") }, "the app log says what was refused")
    }
}
