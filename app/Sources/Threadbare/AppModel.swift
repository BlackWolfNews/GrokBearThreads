import AppKit
import Observation
import ThreadbareCore

enum SidebarMode: Equatable {
    case inbox, snoozed, archive
}

enum ConnectionState: Equatable {
    case connecting
    case connected
    /// The runner isn't listening (or the token file isn't there yet). The
    /// reason is for the banner's tooltip, not its text.
    case runnerDown(String)
    /// A working connection dropped; trying again.
    case lost
    case unauthorized
}

struct Draft: Equatable {
    var text = ""
    var images: [ImageRef] = []
}

/// App state: the runner connection, the thread list, the selection and the
/// open thread sessions. Holds no agent state of its own.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var connection: ConnectionState = .connecting
    var runnerVersion = ""
    var accounts: [Account] = []
    var defaults = RunnerDefaults(cwd: NSString("~/dev/me/misc").expandingTildeInPath, accountId: "claude-main")
    var threads: [String: ThreadSummary] = [:] {
        willSet { SidebarScroll.threadsWillChange() }
    }
    var selection: String?
    var sidebarMode: SidebarMode = .inbox
    var searchText = "" {
        didSet { scheduleSearch() }
    }
    var searchResults: [ThreadSummary]?
    var archiveQuery = ""
    var archiveLoaded = false
    var errorMessage: String?
    var focusSearch = false
    var focusComposer = 0
    var now = Date()
    var drafts: [String: Draft] = [:]
    /// The first thread list has arrived. Until then the sidebar list stays
    /// empty, so it's filled in one go.
    var threadsLoaded = false
    /// New-thread settings shown on the composer.
    var newThreadCwd: String?
    var newThreadAccount: String?
    var newThreadModel: String?
    var newThreadAsk = false

    @ObservationIgnored private(set) var client: RPCClient?
    @ObservationIgnored private var sessions: [String: ThreadSession] = [:]
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var markSeenTask: Task<Void, Never>?
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored let transcript = TranscriptController()
    @ObservationIgnored var dataDir = RunnerConfig.dataDir()
    @ObservationIgnored var notificationsEnabled = true
    @ObservationIgnored var onThreadsLoaded: (() -> Void)?
    @ObservationIgnored private var clockTimer: Timer?

    static let maxSessions = 24
    static let lastAccountKey = "lastAccountId"
    /// The account threads don't get a badge for. Fixed, unlike the runner's
    /// `defaults.accountId` (the last one used), so badges don't move about.
    static let mainAccountId = "claude-main"
    /// The error banner text shown for a connection problem, so it can be
    /// cleared when the connection comes back.
    @ObservationIgnored private var connectionErrorMessage: String?

    init() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    // MARK: Derived

    var sections: ThreadSections { ThreadSections.build(threads.values, now: now) }
    var snoozed: [ThreadSummary] { ThreadSections.snoozed(threads.values, now: now) }
    var archived: [ThreadSummary] { ThreadSections.archived(threads.values, matching: archiveQuery) }
    var selectedThread: ThreadSummary? { selection.flatMap { threads[$0] } }

    var lastAccountId: String {
        UserDefaults.standard.string(forKey: Self.lastAccountKey) ?? defaults.accountId
    }

    func accountTitle(_ id: String) -> String {
        accounts.first(where: { $0.id == id })?.title ?? id
    }

    /// A short name for the sidebar badge: the part of the account's email
    /// before the @, unless another account shares it.
    func accountShortTitle(_ id: String) -> String {
        let title = accountTitle(id)
        guard let at = title.firstIndex(of: "@") else { return title }
        let local = String(title[..<at])
        let clashes = accounts.filter { $0.id != id && $0.title.hasPrefix(local + "@") }
        return clashes.isEmpty ? local : title
    }

    /// Whether a thread's row shows its account: only when it isn't on the
    /// main account (or the first one, if there's no main).
    func showsAccountBadge(_ thread: ThreadSummary) -> Bool {
        guard !thread.accountId.isEmpty else { return false }
        let main = accounts.contains { $0.id == Self.mainAccountId } || accounts.isEmpty ? Self.mainAccountId : accounts[0].id
        return thread.accountId != main
    }

    // MARK: Connection

    func start() {
        guard connectTask == nil else { return }
        connectTask = Task { await connectLoop() }
    }

    /// Connects, loads, pumps notifications until the socket drops, then
    /// tries again with backoff.
    private func connectLoop() async {
        while !Task.isCancelled {
            // While retrying, the banner keeps saying what went wrong
            // instead of flickering to "Connecting" on every attempt.
            if connection == .connected { connection = .connecting }
            // Every attempt's client is closed when it's done with, so its
            // URLSession (which holds the transport) is let go. Before, each
            // failed attempt leaked one: about 360 an hour with the runner off.
            var attempt: RPCClient?
            do {
                let endpoint = try RunnerConfig.endpoint(dataDir: dataDir)
                let client = RPCClient(transport: WebSocketTransport(url: endpoint.url, token: endpoint.token))
                attempt = client
                try await client.start()
                let hello = try await client.hello(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                self.client = client
                runnerVersion = hello.runnerVersion
                accounts = hello.accounts
                defaults = hello.defaults
                connection = .connected
                clearConnectionError()
                backoff.reset()
                let list = try await client.listThreads(include: archiveLoaded ? [.inbox, .snoozed, .archived] : [.inbox, .snoozed])
                var fresh: [String: ThreadSummary] = [:]
                for thread in list { fresh[thread.id] = thread }
                threads = fresh
                threadsLoaded = true
                onThreadsLoaded?()
                for session in sessions.values where session.state == .loaded {
                    await session.subscribe()
                }
                for session in sessions.values where session.state != .loaded {
                    session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
                }
                await pump(client)
                client.close()
                // reconnectNow() may already have started a new loop with a
                // new client; only the loop that owns the client clears it.
                guard self.client === client else { return }
                self.client = nil
                for session in sessions.values { session.connectionLost() }
                connection = .lost
            } catch RPCError.unauthorized {
                attempt?.close()
                guard !Task.isCancelled else { return }
                client = nil
                connection = .unauthorized
            } catch {
                attempt?.close()
                guard !Task.isCancelled else { return }
                client = nil
                connection = .runnerDown(error.localizedDescription)
            }
            let delay = backoff.next()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func pump(_ client: RPCClient) async {
        for await notification in client.notifications {
            switch notification {
            case .threadUpdated(let thread):
                receive(thread)
            case .threadEvent(let threadId, let event):
                sessions[threadId]?.receive(event)
            case .runnerNotice(let level, let message):
                if level != "info" { errorMessage = message }
            case .other:
                break
            }
        }
    }

    #if DEBUG
    /// Tests drive AppModel over a fake transport.
    func useClientForTesting(_ client: RPCClient) {
        self.client = client
        connection = .connected
    }
    #endif

    /// Try again straight away (after starting the runner, say).
    func reconnectNow() {
        connection = .connecting
        backoff.reset()
        connectTask?.cancel()
        connectTask = nil
        client?.close()
        start()
    }

    func startRunner() {
        Task {
            let result = await RunnerLauncher.start()
            if let failure = result { errorMessage = failure }
            try? await Task.sleep(for: .milliseconds(600))
            reconnectNow()
        }
    }

    private func receive(_ thread: ThreadSummary) {
        let previous = threads[thread.id]
        threads[thread.id] = thread
        let becameNeedy = thread.needsYou && previous?.needsYou != true
        let showing = NSApp.isActive && selection == thread.id
        if becameNeedy && !showing && notificationsEnabled {
            Notifier.post(thread: thread)
        }
        if showing && thread.lastSeq > thread.lastSeenSeq && thread.status != .waiting {
            scheduleMarkSeen(thread.id)
        }
    }

    // MARK: Selection and sessions

    func select(_ threadId: String?) {
        selection = threadId
        guard let threadId else { return }
        let session = session(for: threadId)
        if session.state == .idle || session.state.isFailed {
            session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
        }
        if let thread = threads[threadId], thread.needsYou || thread.lastSeq > thread.lastSeenSeq {
            scheduleMarkSeen(threadId)
        }
    }

    func session(for threadId: String) -> ThreadSession {
        if let existing = sessions[threadId] {
            existing.lastUsed = Date()
            return existing
        }
        let session = ThreadSession(threadId: threadId, app: self)
        sessions[threadId] = session
        evictSessions()
        return session
    }

    var loadedSessionCount: Int { sessions.count }

    private func evictSessions() {
        guard sessions.count > Self.maxSessions else { return }
        let victims = sessions.values
            .filter { $0.threadId != selection }
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(sessions.count - Self.maxSessions)
        for victim in victims {
            victim.unsubscribe()
            sessions[victim.threadId] = nil
        }
    }

    private func scheduleMarkSeen(_ threadId: String) {
        markSeenTask?.cancel()
        markSeenTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let client, let thread = threads[threadId], NSApp.isActive, selection == threadId else { return }
            if let updated = try? await client.markSeen(threadId: threadId, seq: thread.lastSeq) {
                threads[threadId] = updated
            }
        }
    }

    func appBecameActive() {
        if let selection, let thread = threads[selection], thread.needsYou { scheduleMarkSeen(selection) }
    }

    // MARK: Thread actions

    func newThread() {
        selection = nil
        sidebarMode = .inbox
        focusComposer += 1
    }

    /// Sends the draft for `threadId` (or starts a new thread with the "new"
    /// draft). The box empties straight away, but the text and images go
    /// back in if the runner doesn't take them; while disconnected nothing
    /// is touched at all.
    func send(threadId: String?) {
        let key = threadId ?? "new"
        let draft = drafts[key] ?? Draft()
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !draft.images.isEmpty else { return }
        guard let client, connection == .connected else {
            showConnectionError("Not connected to the runner, so that wasn't sent. It's still in the box.")
            return
        }
        drafts[key] = nil
        if let threadId {
            Task {
                do {
                    try await client.send(threadId: threadId, text: trimmed, images: draft.images)
                } catch {
                    restoreDraft(draft, key: key)
                    show(error)
                }
            }
        } else {
            let account = newThreadAccount ?? lastAccountId
            let request = NewThreadRequest(
                text: trimmed, images: draft.images, cwd: newThreadCwd ?? defaults.cwd, accountId: account,
                model: newThreadModel, permissionMode: newThreadAsk ? .ask : .full
            )
            Task {
                do {
                    let thread = try await client.createThread(request)
                    UserDefaults.standard.set(account, forKey: Self.lastAccountKey)
                    // Folder, model and "Ask before edits" were for this
                    // thread; the next one starts from the defaults again.
                    // The account sticks (the plan's "last-used account").
                    newThreadCwd = nil
                    newThreadModel = nil
                    newThreadAsk = false
                    threads[thread.id] = thread
                    select(thread.id)
                } catch {
                    restoreDraft(draft, key: key)
                    show(error)
                }
            }
        }
    }

    /// Puts an unsent draft back, keeping anything typed since.
    private func restoreDraft(_ draft: Draft, key: String) {
        let current = drafts[key] ?? Draft()
        var restored = draft
        if !current.text.isEmpty {
            restored.text = draft.text.isEmpty ? current.text : draft.text + "\n\n" + current.text
        }
        restored.images += current.images
        drafts[key] = restored
    }

    func interrupt() {
        guard let client, let threadId = selection else { return }
        Task { try? await client.interrupt(threadId: threadId) }
    }

    func update(_ threadId: String, _ update: ThreadUpdate) {
        guard let client else { return }
        Task {
            do {
                threads[threadId] = try await client.updateThread(threadId, update)
            } catch {
                show(error)
            }
        }
    }

    /// Archive (Mike calls it settling): leaves the inbox, stops its CLI.
    func archive(_ threadId: String? = nil) {
        guard let threadId = threadId ?? selection else { return }
        let next = neighbour(of: threadId)
        update(threadId, ThreadUpdate(archived: true))
        if selection == threadId { select(next) }
    }

    func unarchive(_ threadId: String) {
        update(threadId, ThreadUpdate(archived: false))
    }

    func snooze(_ threadId: String? = nil, until date: Date) {
        guard let threadId = threadId ?? selection else { return }
        let next = neighbour(of: threadId)
        update(threadId, ThreadUpdate(snoozedUntil: .some(date)))
        if selection == threadId { select(next) }
    }

    func unsnooze(_ threadId: String) {
        update(threadId, ThreadUpdate(snoozedUntil: .some(nil)))
    }

    func setPermission(_ threadId: String, ask: Bool) {
        update(threadId, ThreadUpdate(permissionMode: ask ? .ask : .full))
    }

    func setModel(_ threadId: String, _ model: String?) {
        update(threadId, ThreadUpdate(model: .some(model)))
    }

    func setAccount(_ threadId: String, _ accountId: String) {
        UserDefaults.standard.set(accountId, forKey: Self.lastAccountKey)
        update(threadId, ThreadUpdate(accountId: accountId))
    }

    func setCwd(_ threadId: String, _ cwd: String) {
        update(threadId, ThreadUpdate(cwd: cwd))
    }

    /// The thread below (or above) in the inbox, to select after archiving.
    private func neighbour(of threadId: String) -> String? {
        let ordered = sections.all.map(\.id)
        guard let index = ordered.firstIndex(of: threadId) else { return nil }
        if index + 1 < ordered.count { return ordered[index + 1] }
        return index > 0 ? ordered[index - 1] : nil
    }

    func loadArchive() {
        guard let client else { return }
        Task {
            if let list = try? await client.listThreads(include: [.archived]) {
                for thread in list { threads[thread.id] = thread }
                archiveLoaded = true
            }
        }
    }

    func importImages(_ urls: [URL]) async -> [ImageRef] {
        guard let client else { return [] }
        var refs: [ImageRef] = []
        for url in urls {
            do {
                refs.append(try await client.importMedia(path: url.path))
            } catch {
                show(error)
            }
        }
        return refs
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if let client, let results = try? await client.searchThreads(query, limit: 50) {
                searchResults = results
            } else {
                searchResults = threads.values.filter { ThreadSections.matches($0, query) }.sorted { $0.lastActivityAt > $1.lastActivityAt }
            }
        }
    }

    func show(_ error: Error) {
        switch error as? RPCError {
        case .disconnected?, .timeout?, .connectFailed?:
            showConnectionError(error.localizedDescription)
        default:
            errorMessage = error.localizedDescription
        }
    }

    private func showConnectionError(_ message: String) {
        errorMessage = message
        connectionErrorMessage = message
    }

    /// A banner about being disconnected is out of date once connected again.
    private func clearConnectionError() {
        if let stale = connectionErrorMessage, errorMessage == stale { errorMessage = nil }
        connectionErrorMessage = nil
    }
}
