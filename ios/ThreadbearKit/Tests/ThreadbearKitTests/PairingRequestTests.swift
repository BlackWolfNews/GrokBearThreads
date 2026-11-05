import Foundation
import Testing
@testable import ThreadbearKit

/// Every pairing link waits for a yes, paired or not (Daybreak finding 5:
/// an expired token left the phone unpaired, and a link then replaced the
/// saved server, token and runner keys without asking).
@MainActor @Suite struct PairingRequestTests {
    static let macKey = "pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk="
    static let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
    static let old = Pairing(deploymentURL: URL(string: "https://happy-bear-123.convex.cloud")!, token: "tb_expired")

    static func link(host: String, token: String = "tb_new", key: String? = nil) -> URL {
        Pairing(deploymentURL: URL(string: "https://\(host)")!, token: token, runnerKeys: key.map { ["mac": $0] } ?? [:]).link
    }

    /// What the app keeps, as plain values, to see that asking and
    /// cancelling never touch them.
    final class Saved {
        var pairing: Pairing?
        var stores: [String: MemoryRunnerKeyStore] = [:]
        func keys(_ p: Pairing) -> any RunnerKeyStore {
            let host = p.deploymentURL.host()!
            if let s = stores[host] { return s }
            let s = MemoryRunnerKeyStore()
            stores[host] = s
            return s
        }
    }

    /// The finding's first test: the old token is expired (the phone shows
    /// the pair screen, `isPaired` is false), and a link from outside still
    /// asks before anything changes, naming the new server and the key change.
    @Test func aLinkAfterTheTokenExpiredIsAskedAbout() {
        let saved = Saved()
        saved.pairing = Self.old
        let oldStore = MemoryRunnerKeyStore(["mac": Self.macKey])
        saved.stores["happy-bear-123.convex.cloud"] = oldStore
        let gate = PairingGate()
        let url = Self.link(host: "evil-fox-9.convex.cloud", key: Self.otherKey)
        #expect(gate.ask(url, allowLocal: false, current: saved.pairing, keys: saved.keys))
        let request = try! #require(gate.pending)
        #expect(request.title == "Pair with evil-fox-9.convex.cloud?")
        #expect(request.message.contains("from happy-bear-123.convex.cloud to evil-fox-9.convex.cloud"))
        #expect(request.addedKeys == 1)
        #expect(request.message.contains("adds 1 Mac"))
        // Asking saved nothing: the old pairing and its keys are as they were,
        // and the new server's store is still empty.
        #expect(saved.pairing == Self.old)
        #expect(oldStore.key(for: "mac") == Self.macKey)
        #expect(saved.stores["evil-fox-9.convex.cloud"]?.key(for: "mac") == nil)
    }

    /// The first pairing is asked about too.
    @Test func theFirstPairingIsAskedAbout() throws {
        let gate = PairingGate()
        let saved = Saved()
        #expect(gate.ask(Self.link(host: "happy-bear-123.convex.cloud", key: Self.macKey), allowLocal: false, current: nil, keys: saved.keys))
        let request = try #require(gate.pending)
        #expect(request.message.hasPrefix("This link pairs the phone with the server at happy-bear-123.convex.cloud."))
        #expect(request.replacesHost == nil)
    }

    /// The finding's second test: Cancel keeps the old server, token and keys,
    /// and leaves nothing to pair with afterwards.
    @Test func cancelKeepsTheOldPairingAndKeys() {
        let saved = Saved()
        saved.pairing = Self.old
        let store = MemoryRunnerKeyStore(["mac": Self.macKey])
        saved.stores["happy-bear-123.convex.cloud"] = store
        let gate = PairingGate()
        // Same server, a new token and a different key for the same Mac.
        let url = Self.link(host: "happy-bear-123.convex.cloud", token: "tb_attacker", key: Self.otherKey)
        #expect(gate.ask(url, allowLocal: false, current: saved.pairing, keys: saved.keys))
        #expect(gate.pending?.changedKeys == 1)
        #expect(gate.pending?.message.contains("new token for happy-bear-123.convex.cloud") == true)
        #expect(gate.pending?.message.contains("changes the key of 1 Mac") == true)
        gate.cancel()
        #expect(gate.pending == nil)
        #expect(gate.accept() == nil)
        #expect(saved.pairing == Self.old)
        #expect(saved.pairing?.token == "tb_expired")
        #expect(store.key(for: "mac") == Self.macKey)
    }

    @Test func yesHandsBackTheLinkOnce() throws {
        let gate = PairingGate()
        let url = Self.link(host: "happy-bear-123.convex.cloud")
        gate.ask(url, allowLocal: false, current: nil, keys: Saved().keys)
        #expect(try #require(gate.accept()).link == url)
        #expect(gate.accept() == nil)
    }

    @Test func sameKeysSaySo() throws {
        let saved = Saved()
        saved.stores["happy-bear-123.convex.cloud"] = MemoryRunnerKeyStore(["mac": Self.macKey])
        let request = try #require(PairingRequest(link: Self.link(host: "happy-bear-123.convex.cloud", key: Self.macKey),
                                                  allowLocal: false, current: Self.old, keys: saved.keys))
        #expect(!request.changesKeys)
        #expect(request.message.contains("stay the same"))
    }

    @Test func notAPairingLinkIsntHeld() {
        let gate = PairingGate()
        #expect(!gate.ask(URL(string: "threadbear://pair?url=https://evil.example.com&token=t")!, allowLocal: false, current: nil, keys: Saved().keys))
        #expect(gate.pending == nil)
    }
}
