import Foundation
import XCTest
@testable import Threadbear
import ThreadbearCore

@MainActor
final class ChromePanelSignInTests: XCTestCase {
    func testBundledExtensionCanBePreparedWithOnlyTheExpectedPermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("threadbear-extension-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prepared = try ChromePanelSignIn.extensionFolder(at: folder)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: prepared.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["permissions"] as? [String], ["activeTab", "declarativeNetRequestWithHostAccess", "alarms"])
        XCTAssertEqual(manifest["host_permissions"] as? [String], ["https://dashboard.convex.dev/api/auth/callback*"])
        for name in ["bridge.mjs", "worker.mjs"] {
            XCTAssertFalse(try Data(contentsOf: prepared.appendingPathComponent(name)).isEmpty)
        }
    }

    func testLoopbackPageRejectsWrongStateAndConsumesTheCallbackOnce() async throws {
        let opened = expectation(description: "Chrome page ready")
        var page: URL?
        let session = ChromePanelSignIn(openPage: { page = $0; opened.fulfill() })
        defer { session.cancel() }
        var callbacks: [URL] = []
        session.start(dashboard: URL(string: "https://dashboard.convex.dev/d/test-deployment")!) { callbacks.append($0) }
        await fulfillment(of: [opened], timeout: 3)
        let start = try XCTUnwrap(page)
        XCTAssertEqual(start.host, "127.0.0.1")
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let (body, response) = try await client.data(from: start)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Threadbear Convex Sign-in"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fake-code"))

        let fragment = try XCTUnwrap(URLComponents(string: "https://test.invalid/?" + (start.fragment ?? "")))
        let login = try XCTUnwrap(fragment.queryItems?.first?.value.flatMap(URL.init(string:)))
        let state = try XCTUnwrap(URLComponents(url: login, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        var callback = try XCTUnwrap(URLComponents(url: start, resolvingAgainstBaseURL: false))
        callback.fragment = nil
        callback.path = callback.path.replacingOccurrences(of: "/start/", with: "/finish/")
        callback.queryItems = [URLQueryItem(name: "code", value: "fake-code"), URLQueryItem(name: "state", value: "/wrong")]
        let (_, rejected) = try await client.data(from: callback.url!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(session.waiting)
        XCTAssertTrue(callbacks.isEmpty)

        callback.queryItems = [URLQueryItem(name: "code", value: "fake-code"), URLQueryItem(name: "state", value: state)]
        let (_, accepted) = try await client.data(from: callback.url!)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first?.host, "dashboard.convex.dev")
        XCTAssertEqual(callbacks.first?.path, "/api/auth/callback")
        XCTAssertTrue(session.finished)
        XCTAssertFalse(session.waiting)

        var replay = URLRequest(url: callback.url!)
        replay.timeoutInterval = 1
        do { _ = try await client.data(for: replay); XCTFail("Listener should be closed after success") }
        catch { /* A consumed handoff has no listening socket. */ }
        XCTAssertEqual(callbacks.count, 1)
    }

    func testCancelClosesTheListenerWithoutSigningIn() async throws {
        let opened = expectation(description: "Chrome page ready")
        var page: URL?
        let session = ChromePanelSignIn(openPage: { page = $0; opened.fulfill() })
        session.start(dashboard: URL(string: "https://dashboard.convex.dev")!) { _ in XCTFail("Cancelled sign-in") }
        await fulfillment(of: [opened], timeout: 3)
        let start = try XCTUnwrap(page)
        session.cancel()
        XCTAssertFalse(session.waiting)
        var request = URLRequest(url: start)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request); XCTFail("Cancelled listener still accepts connections") }
        catch {}
    }
}
