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
    var threads: [String: ThreadSummary] = [:]
    var selection: String?
    var sidebarMode: SidebarMode = .inbox
    var archiveQuery = ""
    /// Archived threads are in `threads` (the first list includes them, for
    /// the Archive count in the sidebar's footer).
    var archiveLoaded = false
    var errorMessage: String?
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
    var newThreadEffort: String?
    var newThreadAsk = false
    /// A sidebar row drawn as if the pointer were over it, so the screenshot
    /// run can show the hover buttons without moving the mouse.
    var hoverOverride: String?
    /// The pane beside the transcript (PanelsView). Shown for any thread
    /// with panels unless Mike has hidden it; which panel is showing is
    /// remembered per thread for the session.
    var panelsShown = UserDefaults.standard.object(forKey: AppModel.panelsShownKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(panelsShown, forKey: Self.panelsShownKey) }
    }
    var panelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: AppModel.panelWidthKey)
        return saved > 0 ? CGFloat(saved) : CGFloat(PanelChoice.defaultWidth)
    }()
    var panelChoice: [String: String] = [:]
    /// Actions whose command is running, as "<threadId>/<actionId>", so
    /// the chip shows it and a second click doesn't start another.
    var runningActions: Set<String> = []
    /// The automation hook's `focus`: a scripted app is never in front, so
    /// it never marked anything read; with this it acts as if Mike were
    /// looking at it. Never set outside a scripted debug run.
    @ObservationIgnored var actsActive = false
    /// Mike can see the window: the app is in front (or acting as if).
    var isLooking: Bool { NSApp.isActive || actsActive }
    /// A runner restart that's waiting for threads to finish or under way,
    /// for the quiet banner (see `banner`).
    private(set) var restart = RunnerRestart()

    @ObservationIgnored private(set) var client: RPCClient?
    @ObservationIgnored private var sessions: [String: ThreadSession] = [:]
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var markSeenTask: Task<Void, Never>?
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored let transcript = TranscriptController()
    @ObservationIgnored var dataDir = RunnerConfig.dataDir()
    @ObservationIgnored var notificationsEnabled = true
    @ObservationIgnored var onThreadsLoaded: (() -> Void)?
    @ObservationIgnored private var clockTimer: Timer?
    /// Where the Copy menu items put things. A scripted debug run points it
    /// at a private pasteboard, so it never touches Mike's clipboard.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var restartExpiry: Task<Void, Never>?
    /// The last reason a connection attempt failed, so a runner that stays
    /// down logs once rather than on every retry.
    @ObservationIgnored private var lastDownReason: String?

    static let maxSessions = 24
    static let lastAccountKey = "lastAccountId"
    static let panelsShownKey = "panelsShown"
    static let panelWidthKey = "panelWidth"
    /// The account threads aren't labelled with. Fixed, unlike the runner's
    /// `defaults.accountId` (the last one used), so labels don't move about.
    static let mainAccountId = "claude-main"
    /// The error banner text shown for a connection problem, so it can be
    /// cleared when the connection comes back.
    @ObservationIgnored private var connectionErrorMessage: String?

    init() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                // Background work that ends sends no thread update, so a
                // pending restart's count is asked for again now and then.
                if self.restart.isPending { self.refreshRunnerStatus() }
            }
        }
    }

    // MARK: Derived

    var sections: ThreadSections { ThreadSections.build(threads.values, now: now) }
    var snoozed: [ThreadSummary] { ThreadSections.snoozed(threads.values, now: now) }
    var archived: [ThreadSummary] { ThreadSections.archived(threads.values, matching: archiveQuery) }
    var archivedCount: Int { threads.values.reduce(0) { $0 + ($1.isArchived ? 1 : 0) } }
    var selectedThread: ThreadSummary? { selection.flatMap { threads[$0] } }

    var lastAccountId: String {
        UserDefaults.standard.string(forKey: Self.lastAccountKey) ?? defaults.accountId
    }

    func accountTitle(_ id: String) -> String {
        accounts.first(where: { $0.id == id })?.title ?? id
    }

    /// The part of the account's email before the @ (see `AccountName`).
    func accountShortTitle(_ id: String) -> String {
        AccountName.short(id, accounts: accounts)
    }

    /// Whether a thread's row names its account: only when it isn't on the
    /// main account.
    func showsAccountLabel(_ thread: ThreadSummary) -> Bool {
        AccountName.isShown(thread.accountId, accounts: accounts, mainId: Self.mainAccountId)
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
                lastDownReason = nil
                AppLog.write("connection", "connected to runner \(hello.runnerVersion) at \(endpoint.url.absoluteString)")
                // Whatever restart there was is over; a new pending one
                // comes back with hello's notice and runner.status.
                updateRestart { $0.connected() }
                refreshRunnerStatus()
                clearConnectionError()
                backoff.reset()
                // Archived threads come too: the sidebar's footer shows how
                // many there are, and they open as fast as live ones.
                let list = try await client.listThreads(include: [.inbox, .snoozed, .archived])
                var fresh: [String: ThreadSummary] = [:]
                for thread in list { fresh[thread.id] = thread }
                threads = fresh
                threadsLoaded = true
                archiveLoaded = true
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
                updateRestart { $0.disconnected(now: Date()) }
                AppLog.write("connection", "lost the connection to the runner")
            } catch RPCError.unauthorized {
                attempt?.close()
                guard !Task.isCancelled else { return }
                client = nil
                connection = .unauthorized
                AppLog.write("connection", "the runner didn't accept the token")
            } catch {
                attempt?.close()
                guard !Task.isCancelled else { return }
                client = nil
                connection = .runnerDown(error.localizedDescription)
                updateRestart { $0.disconnected(now: Date()) }
                if lastDownReason != error.localizedDescription {
                    lastDownReason = error.localizedDescription
                    AppLog.write("connection", "can't reach the runner: \(error.localizedDescription)")
                }
            }
            var delay = backoff.next()
            // A restart is over in a few seconds; backing off to 4 s and
            // more left the window saying "Reconnecting" well after the
            // runner was back.
            if restart.isRestarting(now: Date()) { delay = min(delay, 0.5) }
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
            case .threadDeleted(let threadId):
                forget(threadId)
            case .accountsUpdated(let list):
                // The runner learned something (its model lists, a
                // default it saw a turn run on): replaces hello's list.
                accounts = list
            case .runnerNotice(let level, let message):
                notice(level: level, message)
            case .other:
                break
            }
        }
    }

    /// A restart notice moves the quiet banner along; other warnings and
    /// errors go in the error banner.
    private func notice(level: String, _ message: String) {
        AppLog.write("notice", "\(level): \(message)")
        if restart(notice: message) {
            refreshRunnerStatus()
        } else if level != "info" {
            errorMessage = message
        }
    }

    #if DEBUG
    /// Tests drive AppModel over a fake transport.
    func useClientForTesting(_ client: RPCClient) {
        self.client = client
        connection = .connected
    }

    /// Tests feed it what the runner would: a notice, a status, a drop.
    func noticeForTesting(level: String = "info", _ message: String) { notice(level: level, message) }
    func restartStatusForTesting(_ pending: PendingRestart?) { updateRestart { $0.status(pending, now: Date()) } }
    func connectionLostForTesting() {
        connection = .lost
        updateRestart { $0.disconnected(now: Date()) }
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
        // A thread a pending restart waits for may just have finished.
        if restart.isPending, previous?.status != thread.status { refreshRunnerStatus() }
        let becameNeedy = thread.needsYou && previous?.needsYou != true
        let showing = isLooking && selection == thread.id
        if becameNeedy && !showing && notificationsEnabled {
            Notifier.post(thread: thread)
        }
        if showing && thread.lastSeq > thread.lastSeenSeq && thread.status != .waiting {
            scheduleMarkSeen(thread.id)
        }
    }

    /// A thread deleted on the runner (by an agent's delete_thread, or `tb
    /// delete`) disappears from every list straight away.
    private func forget(_ threadId: String) {
        threads[threadId] = nil
        drafts[threadId] = nil
        if let session = sessions.removeValue(forKey: threadId) { session.unsubscribe() }
        if selection == threadId { selection = nil }
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
            guard !Task.isCancelled, let client, let thread = threads[threadId], isLooking, selection == threadId else { return }
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
                model: newThreadModel, effort: newThreadEffort, permissionMode: newThreadAsk ? .ask : .full
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
                    newThreadEffort = nil
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

    /// ⌘E: archives the open thread, or brings it back if it's archived.
    func toggleArchive() {
        guard let thread = selectedThread else { return }
        if thread.isArchived { unarchive(thread.id) } else { archive(thread.id) }
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

    func setEffort(_ threadId: String, _ effort: String?) {
        update(threadId, ThreadUpdate(effort: .some(effort)))
    }

    func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
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

    func showArchive() {
        sidebarMode = .archive
        loadArchive()
    }

    /// Refreshes the archived threads (the first list already has them).
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

    func show(_ error: Error) {
        AppLog.write("rpc", "error: \(error.localizedDescription)")
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

    // MARK: Runner restarts

    /// A restart notice moves the banner along straight away. Returns false
    /// for any other notice.
    private func restart(notice message: String) -> Bool {
        var handled = false
        updateRestart { handled = $0.notice(message, now: Date()) }
        return handled
    }

    private func updateRestart(_ change: (inout RunnerRestart) -> Void) {
        let before = restart
        var after = before
        change(&after)
        guard after != before else { return }
        restart = after
        if case .restarting = after.phase, !(before.phase.isRestarting) {
            AppLog.write("restart", "the runner is restarting")
            // The banner goes back to "Can't reach the runner" if it doesn't
            // come back; `now` changing is what makes the view look again.
            restartExpiry?.cancel()
            restartExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(RunnerRestart.patience + 1))
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        } else if let text = after.pendingText, text != before.pendingText {
            AppLog.write("restart", text)
        } else if after.phase == .none {
            restartExpiry?.cancel()
        }
    }

    /// Asks `runner.status` which threads a restart waits for. Coalesced:
    /// a burst of thread updates asks once.
    func refreshRunnerStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let client = self.client, self.connection == .connected else { return }
            do {
                let status = try await client.runnerStatus()
                guard !Task.isCancelled, self.client === client else { return }
                self.updateRestart { $0.status(status.pendingRestart, now: Date()) }
            } catch RPCError.server(let code, _) where code == -32601 {
                // A runner older than runner.status: its notices are all there is.
            } catch {
                AppLog.write("rpc", "runner.status failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Banner

    /// The line under the toolbar about the runner, if there's anything to
    /// say: a restart waiting or under way (quiet), or a connection problem.
    var banner: Banner? {
        let restarting = restart.isRestarting(now: max(now, Date()))
        switch connection {
        case .connected:
            if restarting {
                return Banner(style: .quiet, icon: nil, text: "The runner is restarting now.")
            }
            if let text = restart.pendingText(isWaitingOnYou: { self.threads[$0]?.status == .waiting }) {
                return Banner(style: .quiet, icon: "arrow.clockwise", text: text,
                              detail: restart.waitingForText { self.threads[$0]?.title })
            }
            return nil
        case .connecting, .lost, .runnerDown:
            // While a restart is under way the runner is meant to be down
            // for a moment: say so quietly, with no buttons to press.
            if restarting {
                return Banner(style: .quiet, icon: nil, text: "The runner is restarting. Reconnecting…")
            }
            switch connection {
            case .runnerDown(let reason):
                // One plain sentence; the raw reason is in the tooltip.
                return Banner(style: .warning, icon: "bolt.horizontal.circle", text: "Can't reach the runner.", detail: reason,
                              showStart: canStartRunner, showRetry: true)
            case .lost:
                return Banner(style: .warning, icon: "bolt.horizontal", text: "Lost the connection to the runner. Reconnecting…", showRetry: true)
            default:
                return Banner(style: .warning, icon: "bolt.horizontal", text: "Connecting to the runner…", showRetry: true)
            }
        case .unauthorized:
            return Banner(style: .warning, icon: "lock", text: "The runner didn't accept the token in secrets/runner-token.", showRetry: true)
        }
    }

    /// "Start runner" kickstarts the installed runner's LaunchAgent, which
    /// only helps an app pointed at that runner's data folder. A debug app
    /// against the mock or a dev runner must never start the live one.
    var canStartRunner: Bool {
        dataDir.standardizedFileURL.path == RunnerConfig.defaultDataDir.standardizedFileURL.path
    }

    /// What "Copy debug info" says to run for a row's events: a bare `tb`
    /// for the installed runner, a dev runner's own `<home>/tb`
    /// (dev-runner.sh writes one), the data folder in front of `tb` for any
    /// other runner, and the fixture's lines for the mock.
    var eventsSource: RowDebug.EventsSource {
        if runnerVersion.hasPrefix("0.0.0-mock") { return .fixture }
        if canStartRunner { return .tb("tb") }
        let own = dataDir.appendingPathComponent("tb").path
        if FileManager.default.isExecutableFile(atPath: own) { return .tb(Self.shellQuoted(own)) }
        return .tb("THREADBARE_HOME=\(Self.shellQuoted(dataDir.path)) tb")
    }

    /// As a shell would need it typed: the default data folder has a space.
    static func shellQuoted(_ text: String) -> String {
        if text.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Copying

    func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Panels

    /// Whether the pane is beside this thread's transcript.
    func showsPanels(for thread: ThreadSummary) -> Bool { panelsShown && !thread.panels.isEmpty }

    func activePanel(for thread: ThreadSummary) -> Panel? {
        PanelChoice.active(in: thread.panels, remembered: panelChoice[thread.id])
    }

    func choosePanel(_ panelId: String, in threadId: String) {
        panelChoice[threadId] = panelId
        panelsShown = true
    }

    func togglePanels() { panelsShown.toggle() }

    func setPanelWidth(_ width: CGFloat, columnWidth: CGFloat) {
        panelWidth = CGFloat(PanelChoice.clampedWidth(Double(width), paneColumnWidth: Double(columnWidth)))
    }

    func savePanelWidth() {
        UserDefaults.standard.set(Double(panelWidth), forKey: Self.panelWidthKey)
    }

    static func actionKey(threadId: String, actionId: String) -> String { "\(threadId)/\(actionId)" }

    func isRunning(action: Action, in threadId: String) -> Bool {
        runningActions.contains(Self.actionKey(threadId: threadId, actionId: action.id))
    }

    /// Runs an action chip: the runner sends a prompt action as a message,
    /// or runs a command action and puts its output in the transcript.
    func runAction(_ action: Action, in threadId: String) {
        let key = Self.actionKey(threadId: threadId, actionId: action.id)
        guard !runningActions.contains(key), let client else { return }
        runningActions.insert(key)
        Task {
            do {
                _ = try await client.runAction(threadId: threadId, actionId: action.id)
            } catch {
                errorMessage = "\(action.title) didn't run: \(error.localizedDescription)"
            }
            runningActions.remove(key)
        }
    }

    /// An image panel's latest picture, or nil when the runner can't be
    /// asked (not connected, an old runner).
    func renderPanel(threadId: String, panelId: String) async -> PanelRender? {
        guard let client else { return nil }
        do {
            return try await client.renderPanel(threadId: threadId, panelId: panelId)
        } catch {
            AppLog.write("panels", "render \(panelId) failed: \(error)")
            return PanelRender(note: "Couldn't get a picture from the runner.")
        }
    }
}

/// What `ConnectionBanner` shows.
struct Banner: Equatable {
    enum Style: String {
        /// A restart: expected, nothing to do. Grey text, no buttons.
        case quiet
        /// The runner can't be reached: yellow, with Try again.
        case warning
    }

    var style: Style
    /// An SF Symbol, or nil for a spinner.
    var icon: String?
    var text: String
    var detail: String?
    var showStart = false
    var showRetry = false
}

private extension RunnerRestart.Phase {
    var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }
}
