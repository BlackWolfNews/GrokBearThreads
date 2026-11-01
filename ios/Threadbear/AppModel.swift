import Foundation
import Observation
import SwiftUI
import ThreadbearKit
import UIKit

/// The app's live state: who it's paired with, the runners and the three
/// thread lists, each a Convex subscription kept open while the app runs.
@MainActor @Observable
final class AppModel {
    private(set) var pairing: Pairing?
    private(set) var backend: (any Backend)?
    private(set) var runners: [PhoneRunner] = []
    /// The projects by id, for the rows' icons (backend API 5 carries them).
    private(set) var projects: [String: PhoneProject] = [:]
    /// The logins and their models (backend API 20), for the new thread pickers.
    private(set) var accounts: [PhoneAccount] = []
    /// The Pocket's cards, from the file until the backend answers, so they
    /// show with no signal.
    private(set) var pocket: [PocketCard] = []
    var showsPocket: Bool { isFake || !pocket.isEmpty || (apiVersion ?? 0) >= BackendCompatibility.pocketAPIVersion }
    /// `-ThreadbearPocket`: start with the Pocket open, for screenshots and
    /// for checking it on the phone, where nothing can tap the button.
    var opensPocketAtLaunch = false
    private(set) var inbox: [PhoneThread] = []
    /// Rows sliding off the inbox on their way out (`archive`).
    private(set) var slidingOff: Set<String> = []
    /// Archived from this phone, kept out of the lists until Convex says the
    /// runner has done it, which waits for the Mac if it's asleep.
    private var archiving: Set<String> = []
    private(set) var hibernating: [PhoneThread] = []
    private(set) var den: [PhoneThread] = []
    /// For each thread a schedule will message, the one due soonest: the
    /// inbox's Waiting section.
    private(set) var wakes: [String: PhoneSchedule] = [:]
    /// How many are hibernating and archived (backend API 16), for the
    /// folded headings. Nil on an older backend.
    private(set) var counts: PhoneCounts?
    /// Which headings are folded, remembered across launches.
    private(set) var folds = SectionFolds(saved: UserDefaults.standard.stringArray(forKey: "foldedSections"))
    /// A search is on: it looks in the put-away lists too, so they load.
    private(set) var searching = false
    /// The live thread lists, one subscription per view that's wanted
    /// (`folds.views`). A folded Hibernating or Archived has none.
    private var listTasks: [ThreadsView: Task<Void, Never>] = [:]
    /// The lists that have had their first answer from Convex. Until then
    /// a list is loading, not empty: saying "Nothing in the inbox" at
    /// launch, before anything had arrived, read as if it was (Mike, 30 Oct).
    private(set) var loaded: Set<ThreadsView> = []
    private(set) var connected = true
    /// The token was refused (expired or revoked): the app shows pairing again.
    private(set) var authProblem: String?
    private(set) var lastError: String?
    /// Set when the Mac's backend is older than this app needs.
    private(set) var backendProblem: String?
    /// The backend's API version once phone:me has answered (nil before).
    private(set) var apiVersion: Int?
    /// Whether threads read phone:messages (API 2) rather than phone:thread's
    /// newest 20 plus the runner's paging.
    var hasMessagePages: Bool { (apiVersion ?? 0) >= BackendCompatibility.messagePagesAPIVersion }

    /// Archived threads past the den's newest 100 with these words in
    /// (API 16). Empty from an older backend, or when the call fails: the
    /// search still shows what the phone has, so a failure isn't worth a toast.
    func searchOlderArchived(_ text: String) async -> [PhoneThread] {
        guard let backend, (apiVersion ?? 0) >= BackendCompatibility.searchAPIVersion else { return [] }
        return (try? await backend.search(text)) ?? []
    }
    /// When this phone is notified, kept on the phone and sent to the backend
    /// with each registration and change (API 3).
    private(set) var notifyMode: NotifyMode = NotifyMode(rawValue: UserDefaults.standard.string(forKey: "notifyMode") ?? "") ?? .away
    /// The setting shows once the backend takes it and notifications are on.
    var canChooseNotifications: Bool {
        !isFake && apnsToken != nil && (apiVersion ?? 0) >= BackendCompatibility.notificationSettingAPIVersion
    }

    func setNotifyMode(_ mode: NotifyMode) {
        notifyMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "notifyMode")
        guard let backend, let apnsToken, !isFake else { return }
        Task {
            do { try await backend.setNotifications(apnsToken: apnsToken, notify: mode) } catch {
                self.lastError = "Couldn't change notifications: \(error.localizedDescription)"
            }
        }
    }
    /// Ticks every 15 s so "5m" and "Mac offline" stay right.
    private(set) var now = Date.now
    /// A thread a notification tap asked for, for the inbox to open.
    var openThreadId: String?
    /// `-ThreadbearCompose <text>` (Debug only): open New thread with this
    /// typed in, for the screenshots.
    var composeText: String?
    /// `-ThreadbearSearch <text>` (Debug only): start with this in the
    /// inbox's search, for the screenshots.
    var searchText: String?
    /// `-ThreadbearPhoto <path>` (Debug only): start the composers with this
    /// photo, for the screenshots, as nothing can tap the system picker.
    var samplePhoto: Data?

    /// Whether this backend takes photos. The demo does, so App Review sees it.
    var canSendPhotos: Bool { isFake || (apiVersion ?? 0) >= BackendCompatibility.photosAPIVersion }

    /// The models a new thread can start on; empty hides the pickers, as an
    /// older backend would turn an effort down.
    var newThreadModels: [PhoneModelChoice] {
        isFake || (apiVersion ?? 0) >= BackendCompatibility.modelsAPIVersion ? NewThreadChoices.models(accounts) : []
    }

    /// Uploads what isn't up yet and returns the storage ids, in order.
    func upload(_ photos: [PickedPhoto]) async throws -> [String] {
        guard let backend else { throw TransportError.server("Not connected.") }
        var ids: [String] = []
        for photo in photos {
            if photo.storageId == nil { photo.storageId = try await backend.uploadPhoto(photo.jpeg) }
            if let id = photo.storageId { ids.append(id) }
        }
        return ids
    }

    private var tasks: [Task<Void, Never>] = []
    private(set) var apnsToken: String?
    /// Bumped each time the Convex connection is rebuilt (comingBack), so
    /// views holding live queries on the old one start them again.
    private(set) var connection = 0
    private var backgroundedAt: Date?
    /// On the sample threads (FakeBackend) rather than a real deployment:
    /// the demo from the pair screen, or `-ThreadbearFake` for screenshots.
    private(set) var isFake = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        opensPocketAtLaunch = args.contains("-ThreadbearPocket")
        if args.contains("-ThreadbearFake") {
            // -ThreadbearSlowLoad: the lists answer after a few seconds, to see the loading rows.
            // -ThreadbearPictures: and a thread with pictures, "pics".
            connect(FakeBackend(listDelay: args.contains("-ThreadbearSlowLoad") ? .seconds(6) : .zero, pictures: args.contains("-ThreadbearPictures")), pairing: nil)
        } else if let saved = PairingStore.load() {
            connect(ConvexBackend(deploymentURL: saved.deploymentURL, token: saved.token), pairing: saved)
        }
        #if DEBUG
        // `-ThreadbearPair <link>`: pair on launch, since the simulator asks
        // "Open in Threadbear?" for links from outside and nothing can tap it.
        if let i = args.firstIndex(of: "-ThreadbearPair"), i + 1 < args.count, let link = URL(string: args[i + 1]) {
            Task { await pair(with: link) }
        }
        // `-ThreadbearOpen <threadId>`: start on that thread, for screenshots.
        if let i = args.firstIndex(of: "-ThreadbearOpen"), i + 1 < args.count { openThreadId = args[i + 1] }
        if let i = args.firstIndex(of: "-ThreadbearCompose"), i + 1 < args.count { composeText = args[i + 1] }
        if let i = args.firstIndex(of: "-ThreadbearSearch"), i + 1 < args.count { searchText = args[i + 1] }
        if let i = args.firstIndex(of: "-ThreadbearPhoto"), i + 1 < args.count { samplePhoto = FileManager.default.contents(atPath: args[i + 1]) }
        #endif
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.now = .now
            }
        }
    }

    var isPaired: Bool { backend != nil && authProblem == nil }

    var sections: InboxSections {
        InboxSections.build(inbox.filter { !archiving.contains($0.threadId) }, now: now, wakes: wakes)
    }

    /// Archives a thread, gone from the inbox at once. `leavingThread` is for
    /// its own page, which is popping back to the inbox: the row waits for
    /// the page to clear, then slides off where he can see it go (Mike, 31
    /// Oct). The command is only sent once the row has gone, as the runner
    /// can answer within the animation and a list update would snap it away.
    func archive(_ threadId: String, leavingThread: Bool = false) {
        guard let backend, !archiving.contains(threadId), !slidingOff.contains(threadId) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Hibernating threads can be archived from their page but have no inbox row to animate.
        let hasRow = inbox.contains { $0.threadId == threadId }
        Task {
            if hasRow, leavingThread {
                try? await Task.sleep(for: .milliseconds(420))
                withAnimation(.easeIn(duration: 0.24)) { _ = slidingOff.insert(threadId) }
                try? await Task.sleep(for: .milliseconds(240))
            }
            // The Mac may have archived it during the wait; an id that's not
            // in the list would never get cleared by the next list update.
            if inbox.contains(where: { $0.threadId == threadId }) {
                withAnimation(.snappy(duration: 0.25)) { _ = archiving.insert(threadId) }
            }
            slidingOff.remove(threadId)
            do {
                let command = try await backend.update(threadId: threadId, change: .archive)
                for try await status in backend.command(command) {
                    if status?.state == .failed { throw TransportError.server(status?.note ?? "The runner couldn't archive that thread.") }
                    if status?.state == .done { return }
                }
            } catch {
                withAnimation(.snappy(duration: 0.25)) { _ = archiving.remove(threadId) }
                report(error)
            }
        }
    }

    func toggle(_ section: PhoneSection) {
        folds.toggle(section)
        UserDefaults.standard.set(folds.saved, forKey: "foldedSections")
        followLists()
    }

    func setSearching(_ on: Bool) {
        guard on != searching else { return }
        searching = on
        followLists()
    }

    /// How many threads a folded heading hides: the list when it's loaded,
    /// else phone:counts'. Nil when neither knows.
    func count(_ section: PhoneSection) -> Int? {
        switch section {
        case .inbox: sections.inbox.count
        case .running: sections.running.count
        case .waiting: sections.waiting.count
        case .hibernating: loaded.contains(.hibernating) ? hibernating.count : counts?.hibernating
        // The den list is capped at 100; the count isn't.
        case .archived: counts?.den ?? (loaded.contains(.den) ? den.count : nil)
        }
    }

    func threads(_ section: PhoneSection) -> [PhoneThread] {
        switch section {
        case .inbox: sections.inbox
        case .running: sections.running
        case .waiting: sections.waiting
        case .hibernating: hibernating
        case .archived: den
        }
    }

    /// Starts a subscription for each list now wanted and stops the rest,
    /// dropping what a stopped one had so it isn't shown stale later.
    private func followLists() {
        guard let backend else { return }
        let wanted = folds.views(searching: searching)
        for (view, task) in listTasks where !wanted.contains(view) {
            task.cancel()
            listTasks[view] = nil
            loaded.remove(view)
            switch view {
            case .inbox: inbox = []
            case .hibernating: hibernating = []
            case .den: den = []
            }
        }
        for view in wanted where listTasks[view] == nil {
            listTasks[view] = follow(backend.threads(view)) { model, list in
                switch view {
                case .inbox:
                    model.inbox = list
                    // Gone from the list means it's done, so a later unarchive shows.
                    model.archiving.formIntersection(list.map(\.threadId))
                case .hibernating: model.hibernating = list
                case .den: model.den = list
                }
                model.loaded.insert(view)
            }
        }
    }

    /// "Mac offline since 10:42" when no runner has checked in for three
    /// minutes. Things done meanwhile wait until it's back.
    var offlineText: String? {
        guard !runners.isEmpty, !runners.contains(where: { $0.isOnline(at: now) }) else { return nil }
        let newest = runners.max { $0.lastSeenAt < $1.lastSeenAt }!
        let name = runners.count == 1 ? "Mac" : newest.name
        return "\(name) offline since \(RelativeTime.clock(newest.lastSeenAt, now: now))"
    }

    func project(_ id: String) -> PhoneProject? { projects[id] }

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
        pocket = []
        backend = nil
        isFake = false
        runners = []
        projects = [:]
        accounts = []
        inbox = []
        hibernating = []
        den = []
        wakes = [:]
        counts = nil
        loaded = []
    }

    func removePocketCard(_ card: PocketCard) {
        guard let backend else { return }
        // Gone at once, and back if the backend wouldn't have it.
        let before = pocket
        pocket.removeAll { $0.id == card.id }
        Task {
            do { try await backend.removePocketCard(id: card.id) } catch {
                pocket = before
                lastError = error.localizedDescription
            }
        }
    }

    func unpair() {
        PocketStore.standard.clear()
        pocket = []
        PairingStore.clear()
        stop()
        backend = nil
        pairing = nil
        authProblem = nil
        backendProblem = nil
        apiVersion = nil
        runners = []
        projects = [:]
        accounts = []
        inbox = []
        hibernating = []
        den = []
        wakes = [:]
        counts = nil
        loaded = []
    }

    func wentToBackground() { backgroundedAt = .now }

    /// iOS suspends the app soon after it leaves the screen, and the
    /// WebSocket under convex-swift doesn't come back from that: the lists
    /// already showing stay as they were, and anything subscribed afterwards
    /// (opening a thread) waits forever, with no "Reconnecting…" because the
    /// client still thinks it's connected. Mike, 31 Oct: the inbox showed but
    /// no thread opened, and not one phone call had reached Convex in two
    /// hours. So back from the background, a fresh client.
    func comingBack() {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, Date.now.timeIntervalSince(since) > 5,
              !isFake, let pairing, authProblem == nil else { return }
        let kept = loaded
        connect(ConvexBackend(deploymentURL: pairing.deploymentURL, token: pairing.token), pairing: pairing, registerPush: false)
        // What's on screen stays until the fresh answers replace it, rather
        // than flashing the loading rows.
        loaded = kept
        connection += 1
    }

    private func connect(_ backend: any Backend, pairing: Pairing?, registerPush: Bool = true) {
        stop()
        self.backend = backend
        self.pairing = pairing
        isFake = backend is FakeBackend
        authProblem = nil
        if !isFake { pocket = PocketStore.standard.load() }
        tasks.append(follow(backend.runners()) { $0.runners = $1 })
        tasks.append(follow(backend.projects()) { model, list in
            // Two runners could use the same id; the first one wins.
            model.projects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        })
        loaded = []
        followLists()
        tasks.append(follow(backend.accounts()) { $0.accounts = $1 })
        tasks.append(follow(backend.schedules()) { $0.wakes = InboxSections.wakes($1) })
        tasks.append(Task { [weak self] in
            for await up in backend.connectionStates() { self?.connected = up }
        })
        tasks.append(Task { [weak self] in
            guard let identity = try? await backend.me() else { return }
            self?.backendProblem = BackendCompatibility.problem(identity)
            self?.apiVersion = identity.apiVersion ?? 0
            // An older backend has no phone:counts, and asking would only
            // fail and retry.
            if (identity.apiVersion ?? 0) >= BackendCompatibility.countsAPIVersion, !Task.isCancelled, let self {
                self.tasks.append(self.follow(backend.counts()) { $0.counts = $1 })
            }
            if (identity.apiVersion ?? 0) >= BackendCompatibility.pocketAPIVersion, !Task.isCancelled, let self {
                self.tasks.append(self.follow(backend.pocket()) { model, cards in
                    model.pocket = cards
                    if !model.isFake { PocketStore.standard.save(cards) }
                })
            }
        })
        if registerPush, let apnsToken { register(apnsToken) }
    }

    private func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        listTasks.values.forEach { $0.cancel() }
        listTasks = [:]
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
            // The relay key goes to a backend that takes it (API 4); an older
            // one would refuse the extra argument.
            if apiVersion == nil, let identity = try? await backend.me() { apiVersion = identity.apiVersion ?? 0 }
            let pushKey = (apiVersion ?? 0) >= BackendCompatibility.pushKeyAPIVersion ? PushKeyStore.loadOrCreate()?.base64EncodedString() : nil
            do { try await backend.registerDevice(apnsToken: hex, environment: environment, pushKey: pushKey) } catch {
                self.lastError = "Couldn't turn on notifications: \(error.localizedDescription)"
                return
            }
            // A backend before API 3 has no setting; it notifies every time.
            try? await backend.setNotifications(apnsToken: hex, notify: self.notifyMode)
        }
    }

    /// A finished quick ask, kept as a thread by the runner (backend API 10). The thread's id once
    /// it's made; nil if the runner hasn't taken it within a while (the Mac's asleep), in which
    /// case it's made when the runner's back.
    func keepQuickAsk(_ record: QuickAskRecord) async throws -> String? {
        guard let backend else { throw TransportError.server("Pair with your Mac to keep answers as threads.") }
        if let apiVersion, apiVersion < BackendCompatibility.quickAskAPIVersion {
            throw TransportError.server("Update Threadbear on your Mac to keep answers as threads.")
        }
        let commandId = try await backend.quickAsk(record)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await status in backend.command(commandId) {
                    if let threadId = status?.threadId { return threadId }
                    if status?.state == .failed { throw TransportError.server(status?.note ?? "The runner couldn't keep it.") }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
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
