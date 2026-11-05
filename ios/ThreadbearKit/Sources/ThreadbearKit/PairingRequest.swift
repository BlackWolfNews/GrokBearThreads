import Foundation
import Observation

/// A pairing link waiting for a yes, with what saying yes would change: the
/// server the phone talks to, its token, and the Macs it may seal secrets to.
///
/// Every pairing link is asked about, the first pairing included. Any web
/// page or app can open a `threadbear://pair` link, and it used to be asked
/// about only while the phone was paired: an expired or revoked token left
/// it unpaired, and a link then replaced the saved server, token and runner
/// keys without a word (Daybreak finding 5, Nov 2026).
public struct PairingRequest: Sendable, Equatable, Identifiable {
    public var id: URL { link }
    public let link: URL
    public let pairing: Pairing
    /// The server the phone is paired with now, when the link names another one.
    public let replacesHost: String?
    /// Whether the phone already has a pairing (working or not) for this link's server.
    public let samePairedServer: Bool
    /// Macs in the link the phone has no key for yet.
    public let addedKeys: Int
    /// Macs in the link whose key differs from the one the phone kept.
    public let changedKeys: Int

    public var host: String { Self.host(pairing.deploymentURL) }
    public var changesKeys: Bool { addedKeys + changedKeys > 0 }

    /// Nil for a link that isn't a pairing link. `keys` is the runner key
    /// store for the link's server; it's only read, never written: nothing
    /// is kept until Mike says yes.
    public init?(link: URL, allowLocal: Bool, current: Pairing?, keys: (Pairing) -> any RunnerKeyStore) {
        guard let pairing = Pairing.parse(link, allowLocal: allowLocal) else { return nil }
        self.link = link
        self.pairing = pairing
        let newHost = Self.host(pairing.deploymentURL)
        let currentHost = current.map { Self.host($0.deploymentURL) }
        replacesHost = currentHost.flatMap { $0 == newHost ? nil : $0 }
        samePairedServer = currentHost == newHost
        let store = keys(pairing)
        var added = 0, changed = 0
        for (runnerId, key) in pairing.runnerKeys {
            guard let kept = store.key(for: runnerId) else { added += 1; continue }
            // As RunnerKeyPins compares them: bytes, not text.
            if Data(base64Encoded: kept) != Data(base64Encoded: key) { changed += 1 }
        }
        addedKeys = added
        changedKeys = changed
    }

    public var title: String { "Pair with \(host)?" }

    public var message: String {
        var lines: [String] = []
        if let replacesHost {
            lines.append("This link moves the phone from \(replacesHost) to \(host), with a new token.")
        } else if samePairedServer {
            lines.append("This link gives the phone a new token for \(host).")
        } else {
            lines.append("This link pairs the phone with the server at \(host).")
        }
        switch (addedKeys, changedKeys) {
        case (0, 0): lines.append("The Macs the phone can send secrets to stay the same.")
        case (_, 0): lines.append("It adds \(Self.macs(addedKeys)) the phone can send secrets to.")
        case (0, _): lines.append("It changes the key of \(Self.macs(changedKeys)) the phone sends secrets to.")
        default:
            lines.append("It adds \(Self.macs(addedKeys)) and changes the key of \(Self.macs(changedKeys)) the phone sends secrets to.")
        }
        lines.append("Only say yes if you just scanned the code on your own Mac.")
        return lines.joined(separator: " ")
    }

    static func host(_ url: URL) -> String { url.host() ?? url.absoluteString }
    static func macs(_ n: Int) -> String { n == 1 ? "1 Mac" : "\(n) Macs" }
}

/// Holds a pairing link until Mike answers. Nothing about the pairing is
/// saved from here: asking only reads, cancelling forgets the link, and
/// only `accept` hands it back to be paired with.
@MainActor @Observable
public final class PairingGate {
    public private(set) var pending: PairingRequest?

    public init() {}

    /// False for a link that isn't a pairing link, for the caller to say so.
    /// A second link replaces one still waiting.
    @discardableResult
    public func ask(_ link: URL, allowLocal: Bool, current: Pairing?, keys: (Pairing) -> any RunnerKeyStore) -> Bool {
        guard let request = PairingRequest(link: link, allowLocal: allowLocal, current: current, keys: keys) else { return false }
        pending = request
        return true
    }

    /// Yes: the request to pair with, once.
    public func accept() -> PairingRequest? {
        defer { pending = nil }
        return pending
    }

    public func cancel() { pending = nil }
}
