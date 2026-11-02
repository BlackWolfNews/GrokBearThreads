import Foundation

/// What the Connectors panel and its activity bar icon say about the
/// gateway's services (docs/protocol.md, "Connectors"). The accent dot
/// only when a service is signed out, as only Mike can sign it back in;
/// a grey one while the gateway can't be reached or a service is
/// connecting or in error, which usually sorts itself out (as Updates'
/// dots go, 27 Oct).
public enum ConnectorsText {
    /// The services that need Mike to sign in again.
    public static func signedOut(_ s: ConnectorsStatus?) -> [ConnectorService] {
        guard let s, s.state == "ok" else { return [] }
        return s.services.filter { $0.state == "signed_out" }
    }

    public static func needsYou(_ s: ConnectorsStatus?) -> Bool {
        !signedOut(s).isEmpty
    }

    /// The grey dot: something's off that isn't Mike's to fix yet.
    public static func quiet(_ s: ConnectorsStatus?) -> Bool {
        guard let s else { return false }
        if s.state == "unreachable" { return true }
        guard s.state == "ok" else { return false }
        return s.services.contains { $0.state == "error" || $0.state == "connecting" }
    }

    /// The icon's tooltip: "Connectors", then what needs a look, or that
    /// everything's signed in.
    public static func tooltip(_ s: ConnectorsStatus?) -> String {
        var lines = ["Connectors"]
        switch s?.state {
        case "ok":
            let out = signedOut(s).map(\.title)
            if !out.isEmpty { lines.append(list(out) + (out.count == 1 ? " needs signing in" : " need signing in")) }
            let broken = s!.services.filter { $0.state == "error" }.map(\.title)
            if !broken.isEmpty { lines.append(list(broken) + (broken.count == 1 ? " has a problem" : " have problems")) }
            if out.isEmpty && broken.isEmpty { lines.append(s!.services.isEmpty ? "No services yet" : "Everything is signed in") }
        case "unreachable":
            lines.append("Can't reach the gateway")
        case "checking":
            lines.append("Checking")
        default:
            break
        }
        return lines.joined(separator: "\n")
    }

    /// The panel's line when there are no services to list.
    public static func emptyLine(_ s: ConnectorsStatus?) -> String? {
        guard let s else { return "Checking the gateway." }
        switch s.state {
        case "off": return "No Connectors gateway is set up for this runner."
        case "checking": return "Checking the gateway."
        case "unreachable":
            let host = host(s) ?? "the gateway"
            return "Can't reach \(host)" + (s.error.map { ": \($0)." } ?? ".")
        default:
            return s.services.isEmpty ? "The gateway has no services set up." : nil
        }
    }

    /// The gateway's machine, as its owner calls it: "bruce" for
    /// bruce.example.ts.net.
    public static func host(_ s: ConnectorsStatus?) -> String? {
        guard let host = s?.url.flatMap({ URL(string: $0)?.host }), !host.isEmpty else { return nil }
        return host.components(separatedBy: ".").first ?? host
    }

    /// The gateway's admin page, where every service can be connected,
    /// signed out or retried, for the panel's manage button.
    public static func manageURL(_ s: ConnectorsStatus?) -> URL? {
        adminURL(s, path: "/admin")
    }

    /// One service's page on the gateway (its Connect, Disconnect or Try
    /// again), whatever its state. The runner only sends a connect URL for
    /// a service that isn't signed in, so a signed-in one gets the
    /// gateway's page for it, as the runner's own fallback does.
    public static func serviceURL(_ s: ConnectorsStatus?, _ service: ConnectorService) -> URL? {
        if let raw = service.connectUrl, let url = URL(string: raw), isWeb(url) { return url }
        let id = service.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? service.id
        return adminURL(s, path: "/admin/connect/\(id)")
    }

    private static func adminURL(_ s: ConnectorsStatus?, path: String) -> URL? {
        guard let s, s.state != "off", let raw = s.url, let base = URL(string: raw), isWeb(base),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedPath = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A service's state in a word or two.
    public static func stateLine(_ service: ConnectorService) -> String {
        switch service.state {
        case "connected": return "Signed in"
        case "signed_out": return "Signed out"
        case "connecting": return "Connecting"
        case "error": return "Not working"
        case "disabled": return "Turned off"
        default: return service.state.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    /// The button beside a service, or nil when there's nothing to press.
    public static func buttonTitle(_ service: ConnectorService) -> String? {
        guard let url = service.connectUrl, !url.isEmpty else { return nil }
        switch service.state {
        case "connected", "disabled": return nil
        case "signed_out": return "Connect"
        default: return "Reconnect"
        }
    }

    /// "Gmail", "Gmail and Notion", "Gmail, Notion and Sentry".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
