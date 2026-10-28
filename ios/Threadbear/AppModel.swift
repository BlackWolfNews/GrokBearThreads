import Foundation
import Observation
import ThreadbearKit
import UIKit

/// The app's live state: who it's paired with, the runners and the three
/// thread lists, each a Convex subscription kept open while the app runs.
@MainActor @Observable
final class AppModel {
    private(set) var pairing: Pairing?
    private(set) var backend: (any Backend)?
    private(set) var runners: [PhoneRunner] = []
    private(set) var inbox: [PhoneThread] = []
    private(set) var hibernating: [PhoneThread] = []
    private(set) var den: [PhoneThread] = []
    private(set) var connected = true
    /// The token was refused (expired or revoked): the app shows pairing again.
    private(set) var authProblem: String?
    private(set) var lastError: String?
    /// Set when the Mac's backend is older than this app needs.
    private(set) var backendProblem: String?
    /// Ticks every 15 s so "5m" and "Mac offline" stay right.
    private(set) var now = Date.now
    /// A thread a notification tap asked for, for the inbox to open.
    var openThreadId: String?
    /// `-ThreadbearCompose <text>` (Debug only): open New thread with this
    /// typed in, for the screenshots.
    var composeText: String?

    private var tasks: [Task<Void, Never>] = []
    private var apnsToken: String?
    /// On the sample threads (FakeBackend) rather than a real deployment:
    /// the demo from the pair screen, or `-ThreadbearFake` for screenshots.
    private(set) var isFake = false

    init() {
        if ProcessInfo.processInfo.arguments.contains("-ThreadbearFake") {
            connect(FakeBackend(), pairing: nil)
        } else if let saved = PairingStore.load() {
            connect(ConvexBackend(deploymentURL: saved.deploymentURL, token: saved.token), pairing: saved)
        }
        #if DEBUG
        // `-ThreadbearPair <link>`: pair on launch, since the simulator asks
        // "Open in Threadbear?" for links from outside and nothing can tap it.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ThreadbearPair"), i + 1 < args.count, let link = URL(string: args[i + 1]) {
            Task { await pair(with: link) }
        }
        // `-ThreadbearOpen <threadId>`: start on that thread, for screenshots.
        if let i = args.firstIndex(of: "-ThreadbearOpen"), i + 1 < args.count { openThreadId = args[i + 1] }
        if let i = args.firstIndex(of: "-ThreadbearCompose"), i + 1 < args.count { composeText = args[i + 1] }
        #endif
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.now = .now
            }
        }
    }

    var isPaired: Bool { backend != nil && authProblem == nil }

    var sections: InboxSections { InboxSections.build(inbox, now: now) }

    /// "Mac offline since 10:42" when no runner has checked in for three
    /// minutes. Things done meanwhile wait until it's back.
    var offlineText: String? {
        guard !runners.isEmpty, !runners.contains(where: { $0.isOnline(at: now) }) else { return nil }
        let newest = runners.max { $0.lastSeenAt < $1.lastSeenAt }!
        let name = runners.count == 1 ? "Mac" : newest.name
        return "\(name) offline since \(RelativeTime.clock(newest.lastSeenAt, now: now))"
    }

    func runnerName(_ runnerId: String) -> String? {
        runners.count > 1 ? runners.first { $0.runnerId == runnerId }?.name : nil
    }

    // MARK: Pairing

    /// From a `threadbear://pair` link: checks the token works before
    /// keeping it.
    func pair(with link: URL) async {
        #if DEBUG
        let allowLocal = true // the simulator against `npx convex dev` on this Mac
        #else
        let allowLocal = false
        #endif
        guard let pairing = Pairing.parse(link, allowLocal: allowLocal) else {
            lastError = "That link isn't a Threadbear pairing link."
            return
        }
        let backend = ConvexBackend(deploymentURL: pairing.deploymentURL, token: pairing.token)
        do {
            _ = try await backend.me()
            PairingStore.save(pairing)
            connect(backend, pairing: pairing)
        } catch {
            lastError = "The server didn't accept that token: \(error.localizedDescription)"
        }
    }

    /// "Look around with sample threads" on the pair screen. The app is no
    /// use until it's paired with a Mac, so this is how App Review (and
    /// anyone curious) sees it working, on made-up threads that never leave
    /// the phone. Not remembered: a relaunch goes back to pairing.
    func startDemo() {
        lastError = nil
        connect(FakeBackend(), pairing: nil)
    }

    /// Back to the pair screen. A pairing saved before the demo (one whose
    /// token was refused) is left as it was.
    func leaveDemo() {
        stop()
        backend = nil
        isFake = false
        runners = []
        inbox = []
        hibernating = []
        den = []
    }

    func unpair() {
        PairingStore.clear()
        stop()
        backend = nil
        pairing = nil
        authProblem = nil
        backendProblem = nil
        runners = []
        inbox = []
        hibernating = []
        den = []
    }

    private func connect(_ backend: any Backend, pairing: Pairing?) {
        stop()
        self.backend = backend
        self.pairing = pairing
        isFake = backend is FakeBackend
        authProblem = nil
        tasks.append(follow(backend.runners()) { $0.runners = $1 })
        tasks.append(follow(backend.threads(.inbox)) { $0.inbox = $1 })
        tasks.append(follow(backend.threads(.hibernating)) { $0.hibernating = $1 })
        tasks.append(follow(backend.threads(.den)) { $0.den = $1 })
        tasks.append(Task { [weak self] in
            for await up in backend.connectionStates() { self?.connected = up }
        })
        tasks.append(Task { [weak self] in
            guard let identity = try? await backend.me() else { return }
            self?.backendProblem = BackendCompatibility.problem(identity)
        })
        if let apnsToken { register(apnsToken) }
    }

    private func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// Keeps a live query going: on a network error it waits and
    /// subscribes again; a refused token stops everything.
    private func follow<T: Sendable>(_ stream: @autoclosure @escaping () -> AsyncThrowingStream<T, Error>,
                                     _ apply: @escaping (AppModel, T) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    for try await value in stream() {
                        guard let self else { return }
                        apply(self, value)
                        delay = .seconds(1)
                    }
                    return
                } catch TransportError.unauthorized(let message) {
                    self?.authProblem = message
                    return
                } catch {
                    self?.lastError = error.localizedDescription
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
                }
            }
        }
    }

    // MARK: Push

    func didRegister(apnsToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        apnsToken = hex
        register(hex)
    }

    private func register(_ hex: String) {
        guard let backend, !isFake else { return }
        // A development-signed build (every install-phone.sh build) talks to
        // APNs' sandbox; an App Store build would say production.
        let environment = Bundle.main.object(forInfoDictionaryKey: "ThreadbearAPSEnvironment") as? String == "production"
            ? "production" : "sandbox"
        Task {
            do { try await backend.registerDevice(apnsToken: hex, environment: environment) } catch {
                self.lastError = "Couldn't turn on notifications: \(error.localizedDescription)"
            }
        }
    }

    func clearError() { lastError = nil }

    func report(_ error: Error) {
        if case let TransportError.unauthorized(message) = error { authProblem = message } else {
            lastError = error.localizedDescription
        }
    }
}

/// The pairing, in the Keychain (the token) and UserDefaults (the URL).
/// Quick Ask's lesson: a setup flow for another source overwrote its
/// Keychain token, so the token here is keyed by deployment and nothing
/// else ever writes it.
enum PairingStore {
    private static let urlKey = "pairing.deploymentURL"
    private static let service = "com.mikecann.threadbear.token"

    static func load() -> Pairing? {
        guard let raw = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: raw),
              let token = Keychain.read(service: service, account: url.host() ?? raw) else { return nil }
        return Pairing(deploymentURL: url, token: token)
    }

    static func save(_ pairing: Pairing) {
        let account = pairing.deploymentURL.host() ?? pairing.deploymentURL.absoluteString
        Keychain.write(pairing.token, service: service, account: account)
        UserDefaults.standard.set(pairing.deploymentURL.absoluteString, forKey: urlKey)
    }

    static func clear() {
        if let pairing = load() {
            Keychain.delete(service: service, account: pairing.deploymentURL.host() ?? pairing.deploymentURL.absoluteString)
        }
        UserDefaults.standard.removeObject(forKey: urlKey)
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            // Readable after the first unlock, so a notification tap on a
            // locked-then-unlocked phone finds it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
