import XCTest
@testable import ThreadbearCore

final class ConvexPanelSignInTests: XCTestCase {
    private let dashboard = URL(string: "https://dashboard.convex.dev/d/quick-fox-77?tab=data")!
    private let nonce = String(repeating: "a", count: 64)

    func testOnlyHostedConvexDashboardOffersTheBridge() {
        XCTAssertNotNil(ConvexPanelSignIn(dashboardURL: dashboard, nonce: nonce))
        for address in ["http://dashboard.convex.dev", "https://dashboard.convex.dev.evil.test", "https://evil.test", "http://127.0.0.1:6790", "https://dashboard.convex.dev:444", "https://user@dashboard.convex.dev", "https://dashboard.convex.dev/api/auth/callback"] {
            XCTAssertNil(ConvexPanelSignIn(dashboardURL: URL(string: address)!, nonce: nonce), address)
        }
    }

    func testFreshLoginPreservesTheDeploymentAndBindsTheReturnPath() throws {
        let flow = try XCTUnwrap(ConvexPanelSignIn(dashboardURL: dashboard, nonce: nonce))
        let login = try XCTUnwrap(URLComponents(url: flow.loginURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(login.path, "/api/auth/login")
        XCTAssertEqual(login.queryItems, [URLQueryItem(name: "returnTo", value: flow.state)])
        XCTAssertTrue(flow.state.hasPrefix("/d/quick-fox-77?tab=data&"))
        XCTAssertTrue(flow.state.hasSuffix("threadbear_sign_in=" + nonce))
    }

    func testOnlyMatchingSingleUseCodeCanBeReturnedToTheDashboard() throws {
        let flow = try XCTUnwrap(ConvexPanelSignIn(dashboardURL: dashboard, nonce: nonce))
        let query = URLComponents(string: "https://test.invalid")!
        func target(_ items: [URLQueryItem], path: String? = nil) -> String {
            var value = query
            value.path = path ?? flow.callbackPath
            value.queryItems = items
            return value.percentEncodedPath + "?" + value.percentEncodedQuery!
        }
        let valid = [URLQueryItem(name: "code", value: "fake-code"), URLQueryItem(name: "state", value: flow.state)]
        let callback = try XCTUnwrap(flow.callback(requestTarget: target(valid)))
        XCTAssertEqual(callback.host, "dashboard.convex.dev")
        XCTAssertEqual(callback.path, "/api/auth/callback")
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems, valid)
        XCTAssertNil(flow.callback(requestTarget: target(valid, path: "/finish/wrong")))
        XCTAssertNil(flow.callback(requestTarget: target([valid[0], URLQueryItem(name: "state", value: "/")])))
        XCTAssertNil(flow.callback(requestTarget: target([valid[1]])))
        XCTAssertNil(flow.callback(requestTarget: target(valid + [valid[0]])))
        XCTAssertNil(flow.callback(requestTarget: target(valid + [URLQueryItem(name: "url", value: "https://evil.test")])))
        XCTAssertNil(flow.callback(requestTarget: target([URLQueryItem(name: "code", value: ""), valid[1]])))
        XCTAssertNil(flow.callback(requestTarget: "https://evil.test" + target(valid)))
    }
}
