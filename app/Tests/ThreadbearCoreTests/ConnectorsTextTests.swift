import XCTest
@testable import ThreadbearCore

/// The Connectors panel and its icon (ConnectorsText), and the protocol
/// bits they read: `connectors.status` and `connectors.updated`
/// (docs/protocol.md, "Connectors").
final class ConnectorsTextTests: XCTestCase {
    private func status(_ json: String) throws -> ConnectorsStatus {
        try JSONDecoder().decode(ConnectorsStatus.self, from: Data(json.utf8))
    }

    func testDecodesLenientlyAndKeepsUnknownStates() throws {
        let s = try status("""
        {"state":"ok","url":"https://bruce.example.ts.net:8443","checkedAt":"2026-10-29T10:00:00.000Z","version":"0.2.0","future":1,
         "services":[{"id":"notion","title":"Notion","state":"connected","tools":14},
                     {"id":"sentry","state":"signed_out","message":"Expired","connectUrl":"https://bruce.example.ts.net:8443/admin/connect/sentry"},
                     {"id":"odd","title":"Odd","state":"half_awake"},
                     {"title":"no id"}, 3]}
        """)
        XCTAssertEqual(s.state, "ok")
        XCTAssertEqual(s.version, "0.2.0")
        XCTAssertNotNil(s.checkedAt)
        XCTAssertEqual(s.services.map(\.id), ["notion", "sentry", "odd"])
        XCTAssertEqual(s.services[1].title, "sentry", "no title: the id")
        XCTAssertEqual(ConnectorsText.stateLine(s.services[2]), "Half awake")
        let bare = try status("{}")
        XCTAssertEqual(bare.state, "checking")
        XCTAssertEqual(bare.services, [])
    }

    func testTheAccentDotOnlyForASignedOutService() {
        let out = ConnectorService(id: "sentry", title: "Sentry", state: "signed_out", connectUrl: "https://x/admin/connect/sentry")
        let fine = ConnectorService(id: "notion", title: "Notion", state: "connected")
        let broken = ConnectorService(id: "cf", title: "Cloudflare", state: "error", connectUrl: "https://x/admin/connect/cf")
        XCTAssertTrue(ConnectorsText.needsYou(ConnectorsStatus(services: [fine, out])))
        XCTAssertFalse(ConnectorsText.quiet(ConnectorsStatus(services: [fine, out])))
        XCTAssertFalse(ConnectorsText.needsYou(ConnectorsStatus(services: [fine, broken])))
        XCTAssertTrue(ConnectorsText.quiet(ConnectorsStatus(services: [fine, broken])), "an error usually sorts itself out")
        XCTAssertFalse(ConnectorsText.needsYou(ConnectorsStatus(services: [fine])))
        XCTAssertFalse(ConnectorsText.quiet(ConnectorsStatus(services: [fine])))
        // Bruce away: grey, as it isn't a sign-in.
        let away = ConnectorsStatus(state: "unreachable", url: "https://bruce.tail9ef766.ts.net:8443", error: "no answer in 5 seconds")
        XCTAssertFalse(ConnectorsText.needsYou(away))
        XCTAssertTrue(ConnectorsText.quiet(away))
        XCTAssertFalse(ConnectorsText.needsYou(nil))
        XCTAssertFalse(ConnectorsText.quiet(ConnectorsStatus(state: "off")))
    }

    func testTooltipAndLines() {
        let out = ConnectorService(id: "sentry", title: "Sentry", state: "signed_out", connectUrl: "https://x/admin/connect/sentry")
        let out2 = ConnectorService(id: "gmail", title: "Gmail", state: "signed_out", connectUrl: "https://x/admin/connect/gmail")
        let fine = ConnectorService(id: "notion", title: "Notion", state: "connected")
        XCTAssertEqual(ConnectorsText.tooltip(ConnectorsStatus(services: [fine])), "Connectors\nEverything is signed in")
        XCTAssertEqual(ConnectorsText.tooltip(ConnectorsStatus(services: [out, fine])), "Connectors\nSentry needs signing in")
        XCTAssertEqual(ConnectorsText.tooltip(ConnectorsStatus(services: [out, out2])), "Connectors\nSentry and Gmail need signing in")
        let away = ConnectorsStatus(state: "unreachable", url: "https://bruce.tail9ef766.ts.net:8443", error: "no answer in 5 seconds")
        XCTAssertEqual(ConnectorsText.tooltip(away), "Connectors\nCan't reach the gateway")
        XCTAssertEqual(ConnectorsText.emptyLine(away), "Can't reach bruce: no answer in 5 seconds.")
        XCTAssertEqual(ConnectorsText.emptyLine(ConnectorsStatus(state: "off")), "No Connectors gateway is set up for this runner.")
        XCTAssertNil(ConnectorsText.emptyLine(ConnectorsStatus(services: [fine])))
        XCTAssertEqual(ConnectorsText.buttonTitle(out), "Connect")
        XCTAssertNil(ConnectorsText.buttonTitle(fine))
        XCTAssertEqual(ConnectorsText.buttonTitle(ConnectorService(id: "cf", title: "Cloudflare", state: "error", connectUrl: "https://x")), "Reconnect")
        XCTAssertNil(ConnectorsText.buttonTitle(ConnectorService(id: "cf", title: "Cloudflare", state: "signed_out")), "nowhere to go, no button")
    }

    func testConnectorsUpdatedNotification() async throws {
        let transport = FakeTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        transport.push(E.json(["jsonrpc": "2.0", "method": "connectors.updated", "params": ["connectors": ["state": "ok", "services": [["id": "sentry", "title": "Sentry", "state": "signed_out"]]]]]))
        var iterator = client.notifications.makeAsyncIterator()
        guard case .connectorsUpdated(let s)? = await iterator.next() else { return XCTFail("no connectors.updated") }
        XCTAssertEqual(s.services.first?.state, "signed_out")
    }

    func testManageLinksGoToTheGatewaysOwnPages() {
        let base = "https://bruce.example.ts.net:8443"
        let fine = ConnectorService(id: "notion", title: "Notion", state: "connected")
        let out = ConnectorService(id: "sentry", title: "Sentry", state: "signed_out", connectUrl: "\(base)/admin/connect/sentry?from=x")
        let odd = ConnectorService(id: "a/b", title: "Odd", state: "connected")
        let s = ConnectorsStatus(state: "ok", url: base + "/", services: [fine, out, odd])
        XCTAssertEqual(ConnectorsText.manageURL(s)?.absoluteString, "\(base)/admin")
        XCTAssertEqual(ConnectorsText.serviceURL(s, fine)?.absoluteString, "\(base)/admin/connect/notion", "signed in: the gateway's page for it")
        XCTAssertEqual(ConnectorsText.serviceURL(s, out)?.absoluteString, "\(base)/admin/connect/sentry?from=x", "the runner's URL when it sent one")
        XCTAssertEqual(ConnectorsText.serviceURL(s, odd)?.absoluteString, "\(base)/admin/connect/a%2Fb")
        XCTAssertNil(ConnectorsText.manageURL(nil))
        XCTAssertNil(ConnectorsText.manageURL(ConnectorsStatus(state: "off")))
        XCTAssertNil(ConnectorsText.manageURL(ConnectorsStatus(state: "ok", url: "file:///etc")))
        XCTAssertNil(ConnectorsText.serviceURL(ConnectorsStatus(state: "off"), fine))
    }
}
