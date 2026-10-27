import Foundation

/// Where the app connects and with what token. The runner side makes a
/// phone token (`tb phone-token`) and shows it as a QR code of a
/// `threadbear://pair?url=…&token=…` link; the Camera opens the app with
/// it. Quick Ask's lesson: never route a token through the Mac clipboard.
public struct Pairing: Sendable, Hashable {
    public var deploymentURL: URL
    public var token: String

    public init(deploymentURL: URL, token: String) {
        self.deploymentURL = deploymentURL
        self.token = token
    }

    /// Only Convex cloud deployments, over https. `allowLocal` (Debug builds,
    /// for the simulator) also takes the local dev backend on this Mac,
    /// `http://127.0.0.1:3210`.
    public static func parse(_ url: URL, allowLocal: Bool = false) -> Pairing? {
        guard url.scheme == "threadbear", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value,
              let deployment = URL(string: raw), let host = deployment.host(),
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        if allowLocal, deployment.scheme == "http", host == "127.0.0.1" || host == "localhost" {
            return Pairing(deploymentURL: deployment, token: token)
        }
        guard deployment.scheme == "https", host.hasSuffix(".convex.cloud") || host.hasSuffix(".convex.site") else { return nil }
        // The client talks to .convex.cloud; a .site link works too.
        let cloud = host.hasSuffix(".convex.site")
            ? URL(string: "https://" + host.replacingOccurrences(of: ".convex.site", with: ".convex.cloud"))!
            : deployment
        return Pairing(deploymentURL: cloud, token: token)
    }

    public var link: URL {
        var c = URLComponents()
        c.scheme = "threadbear"
        c.host = "pair"
        c.queryItems = [.init(name: "url", value: deploymentURL.absoluteString), .init(name: "token", value: token)]
        return c.url!
    }
}
