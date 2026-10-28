import Foundation

/// The bridge carries only a fresh authorization callback. Convex still
/// exchanges its code and writes its own HttpOnly cookie in the web view.
public struct ConvexPanelSignIn: Sendable {
    public let nonce: String
    public let state: String
    public let loginURL: URL
    public var startPath: String { "/start/" + nonce }
    public var callbackPath: String { "/finish/" + nonce }

    public static func supports(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "dashboard.convex.dev"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && !url.path.hasPrefix("/api/")
    }

    /// Convex's hosted login lives on AuthKit, outside the dashboard.
    /// Match its origin so the native prompt follows email and SSO steps too.
    public static func isLoginPage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return false }
        if url.host == "auth.convex.dev" { return true }
        return url.host == "dashboard.convex.dev"
            && ["/api/auth/login", "/login-error"].contains(url.path)
    }

    public init?(dashboardURL: URL, nonce: String) {
        guard Self.supports(dashboardURL), nonce.count == 64,
              nonce.allSatisfy({ "0123456789abcdef".contains($0) }),
              var destination = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false) else { return nil }
        self.nonce = nonce
        destination.fragment = nil
        var items = destination.queryItems ?? []
        items.removeAll { $0.name == "threadbear_sign_in" }
        items.append(URLQueryItem(name: "threadbear_sign_in", value: nonce))
        destination.queryItems = items
        state = (destination.percentEncodedPath.isEmpty ? "/" : destination.percentEncodedPath)
            + "?" + (destination.percentEncodedQuery ?? "")
        var login = URLComponents(string: "https://dashboard.convex.dev/api/auth/login")!
        login.queryItems = [URLQueryItem(name: "returnTo", value: state)]
        loginURL = login.url!
    }

    /// Request-target, never an arbitrary URL. Reject extra query fields
    /// because Convex's callback also accepts routing hints for other flows.
    public func callback(requestTarget: String) -> URL? {
        guard requestTarget.hasPrefix(callbackPath + "?"),
              let parts = URLComponents(string: "http://127.0.0.1" + requestTarget),
              parts.percentEncodedPath == callbackPath, parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).map(\.value) == [state],
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.count <= 8192 else { return nil }
        var callback = URLComponents(string: "https://dashboard.convex.dev/api/auth/callback")!
        callback.queryItems = items
        return callback.url
    }
}
