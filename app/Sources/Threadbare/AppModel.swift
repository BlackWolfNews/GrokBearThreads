import AppKit
import Observation
import ThreadbareCore

enum SidebarMode: Equatable {
    case inbox, snoozed, archive, scheduled, projects, librarian
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
        didSet {
            refreshDockBadge()
            noteFailedAccounts(from: oldValue)
            // Most updates change a thread, not which threads there are.
            if threads.count != oldValue.count || threads.keys.contains(where: { oldValue[$0] == nil }) {
                ThreadChips.update(threads.keys)
            }
        }
    }
    /// For a thread whose last turn failed: the account it failed on, as it
    /// was when the thread went into `error`. Moving the thread to another
    /// account doesn't clear the status, so this is how the limit line
    /// knows the new account isn't the one that ran out.
    @ObservationIgnored private(set) var failedOnAccount: [String: String] = [:]
    var selection: String?
    /// A sub-agent's transcript is showing instead of its thread's. The
    /// thread stays `selection`, so the sidebar keeps its sub-agents listed
    /// and the toolbar still names it.
    var subagentSelection: SubagentRef?
    var sidebarMode: SidebarMode = .inbox
    var archiveQuery = ""
    /// Archived threads are in `threads` (the first list includes them, for
    /// the Archive view's count).
    var archiveLoaded = false
    var errorMessage: String?
    var focusComposer = 0
    var now = Date()
    var drafts: [String: Draft] = [:]
    @ObservationIgnored var reviewWindows: [String: ReviewWindowController] = [:]
    /// The first thread list has arrived. Until then the sidebar list stays
    /// empty, so it's filled in one go.
    var threadsLoaded = false
    /// New-thread settings shown on the composer. The model and effort
    /// start as whatever was picked last, on any thread, and are kept
    /// across launches; the folder and "Ask before edits" are for one
    /// thread and go back to the defaults after it starts.
    var newThreadCwd: String?
    /// The account Mike picked for the next new thread, for that draft only:
    /// with none picked it's the one with the most room (`newThreadAccountId`).
    var newThreadAccount: String?
    /// The last model and effort picked, per provider ("claude", "codex"),
    /// kept across launches: a Codex model is no use to a Claude thread.
    private(set) var lastModels: [String: String] = AppModel.loadMemory(AppModel.lastModelKey)
    private(set) var lastEfforts: [String: String] = AppModel.loadMemory(AppModel.lastEffortKey)
    var newThreadAsk = false
    /// What the runner says about the Claude and Codex CLIs (`clis.list`,
    /// `clis.updated`). Empty until it's said anything.
    var clis: [CliStatus] = []
    /// Nil until asked; false for a runner older than step 4, which has no
    /// `clis.*` (the usage popover leaves the CLI part out).
    var clisSupported: Bool?
    /// Update failures Mike has dismissed, by "<provider>|<finishedAt>",
    /// so the line under the toolbar stays gone for that failure.
    var dismissedCliFailures: Set<String> = []
    /// The usage popover is open (the sidebar's Usage button, or the
    /// automation's `usage`).
    var usagePopoverShown = false
    /// Bumped to open the composer's model picker from the automation
    /// (`composer-menu` with `show`), the way a click on the chip does.
    var modelPickerRequest = 0
    /// The same for the account picker.
    var accountPickerRequest = 0
    /// Every schedule, in the runner's order (soonest first, then the
    /// paused and finished ones). Replaced whole by `schedules.updated`.
    var schedules: [Schedule] = []
    /// The runner knows about schedules: an older one answers
    /// `schedules.list` with -32601, and then the sidebar has no Scheduled row.
    var schedulesSupported = false
    /// Every project, archived ones too, in the runner's order (newest
    /// activity first). Replaced whole by `projects.updated`.
    var projects: [Project] = []
    /// The runner knows about projects: an older one answers
    /// `projects.list` with -32601, and then the activity bar has no
    /// Projects or Librarian button and threads show no project chips.
    var projectsSupported = false
    /// What the librarian is doing, once `librarian.status` has answered;
    /// replaced by `librarian.updated`.
    var librarian: LibrarianStatus?
    /// The project page showing in the detail area instead of the thread.
    /// Selecting a thread (or a new one) closes it.
    var openProjectId: String?
    /// The runner's settings for the Settings window: nil until
    /// `settings.get` answers, then replaced whole by `settings.updated`.
    var runnerSettings: RunnerSettings?
    /// The runner is from before settings (it answers -32601).
    var settingsUnsupported = false
    /// Why the last change in the Settings window didn't take, shown there.
    var settingsError: String?
    var settingsTab: SettingsTab = .general
    /// Bumped to open the Settings window from the automation (RootView
    /// opens it, as ⌘, does).
    var settingsRequest = 0
    /// The schedule editor sheet, when it's open (ScheduleEditor).
    var scheduleEditor: ScheduleEditorState?
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
    /// The runner's own update (protocol "Runner updates"), for the rail's
    /// updates icon. Nil from a runner older than that.
    var runnerUpdates: RunnerUpdates?
    /// The updates popover is open (on the model so a script can open it).
    var updatesPopoverShown = false

    @ObservationIgnored private(set) var client: RPCClient?
    @ObservationIgnored private var sessions: [String: ThreadSession] = [:]
    /// Sub-agent transcripts, keyed by `SubagentRef.key`. A handful at most.
    @ObservationIgnored private var subagentSessions: [String: ThreadSession] = [:]
    @ObservationIgnored private var subagentPoll: Task<Void, Never>?
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
    /// Claude's keys keep their old names, so a model picked before Codex
    /// came along is still remembered; other providers add ".<provider>".
    static let lastModelKey = "lastModel"
    static let lastEffortKey = "lastEffort"
    static let memoryProviders = ["claude", "codex"]
    static let panelsShownKey = "panelsShown"
    static let panelWidthKey = "panelWidth"
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

    /// The account the next new thread starts on: Mike's pick for this
    /// draft, else the one with the most room on the provider he last used
    /// (`AccountUsageText.pickAccount`, the runner's rule too). Follows
    /// `accounts.updated`, so it moves as usage does until he picks one.
    var newThreadAccountId: String {
        newThreadAccount ?? AccountUsageText.pickAccount(accounts, lastUsedId: lastAccountId) ?? lastAccountId
    }

    func provider(ofAccount id: String) -> String { account(id)?.provider ?? "claude" }

    /// The model and effort the next new thread starts on, for the
    /// provider of the account it starts on.
    var newThreadModel: String? {
        get { lastModels[provider(ofAccount: newThreadAccountId)] }
        set { remember(model: newValue, provider: provider(ofAccount: newThreadAccountId)) }
    }

    var newThreadEffort: String? {
        get { lastEfforts[provider(ofAccount: newThreadAccountId)] }
        set { remember(effort: newValue, provider: provider(ofAccount: newThreadAccountId)) }
    }

    func remember(model: String?, provider: String) {
        lastModels[provider] = model.flatMap { $0.isEmpty ? nil : $0 }
        Self.remember(model, forKey: Self.memoryKey(Self.lastModelKey, provider: provider))
    }

    func remember(effort: String?, provider: String) {
        lastEfforts[provider] = effort.flatMap { $0.isEmpty ? nil : $0 }
        Self.remember(effort, forKey: Self.memoryKey(Self.lastEffortKey, provider: provider))
    }

    static func memoryKey(_ base: String, provider: String) -> String {
        provider == "claude" || provider.isEmpty ? base : base + "." + provider
    }

    private static func loadMemory(_ base: String) -> [String: String] {
        var memory: [String: String] = [:]
        for provider in memoryProviders {
            if let value = UserDefaults.standard.string(forKey: memoryKey(base, provider: provider)), !value.isEmpty { memory[provider] = value }
        }
        return memory
    }

    func accountTitle(_ id: String) -> String {
        account(id).map(AccountName.title) ?? id
    }

    /// The part of the account's email before the @ (see `AccountName`).
    func accountShortTitle(_ id: String) -> String {
        AccountName.short(id, accounts: accounts)
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
                // A step 4 runner puts its CLIs in hello; an older one has
                // none, and `clis.list` tells which.
                clis = hello.clis
                clisSupported = hello.clis.isEmpty ? nil : true
                runnerUpdates = hello.updates
                if hello.clis.isEmpty { loadClis() }
                lastDownReason = nil
                AppLog.write("connection", "connected to runner \(hello.runnerVersion) at \(endpoint.url.absoluteString)")
                // Whatever restart there was is over; a new pending one
                // comes back with hello's notice and runner.status.
                updateRestart { $0.connected() }
                refreshRunnerStatus()
                clearConnectionError()
                backoff.reset()
                // Archived threads come too: the Archive view shows how
                // many there are, and they open as fast as live ones.
                let list = try await client.listThreads(include: [.inbox, .snoozed, .archived])
                var fresh: [String: ThreadSummary] = [:]
                for thread in list { fresh[thread.id] = thread }
                threads = fresh
                threadsLoaded = true
                archiveLoaded = true
                onThreadsLoaded?()
                loadSchedules()
                loadProjects()
                loadSettings()
                for session in sessions.values where session.state == .loaded {
                    await session.subscribe()
                }
                for session in sessions.values where session.state != .loaded {
                    session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
                }
                if let ref = subagentSelection {
                    let session = subagentSession(for: ref)
                    if session.state == .loaded { session.refreshSubagent() } else { session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth) }
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
                if case .reviewUpdated(let review) = event.payload { receiveReview(review, threadId: threadId) }
            case .threadDeleted(let threadId):
                forget(threadId)
            case .accountsUpdated(let list):
                // The runner learned something (its model lists, a
                // default it saw a turn run on, new usage): replaces
                // hello's list.
                accounts = list
            case .clisUpdated(let list):
                clis = list
                clisSupported = true
            case .schedulesUpdated(let list):
                schedules = list
                schedulesSupported = true
            case .projectsUpdated(let list):
                receive(projects: list)
            case .librarianUpdated(let status):
                librarian = status
                projectsSupported = true
            case .settingsUpdated(let settings):
                receive(settings)
            case .runnerNotice(let level, let message):
                notice(level: level, message)
            case .runnerUpdates(let updates):
                runnerUpdates = updates
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
        // The open transcript's "3 sub-agents working in the background"
        // line follows the summary, not the events.
        if previous?.background != thread.background { sessions[thread.id]?.setBackground(thread.background) }
        // The open sub-agent did something: read its transcript again.
        if let ref = subagentSelection, ref.threadId == thread.id,
           previous?.subagents.first(where: { $0.id == ref.subagentId }) != thread.subagents.first(where: { $0.id == ref.subagentId }) {
            subagentSessions[ref.key]?.refreshSubagent()
        }
        // A thread a pending restart waits for may just have finished.
        if restart.isPending, previous?.status != thread.status { refreshRunnerStatus() }
        let becameNeedy = thread.needsYou && previous?.needsYou != true
        let showing = isLooking && selection == thread.id && subagentSelection == nil
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
        if subagentSelection?.threadId == threadId { subagentSelection = nil }
        for key in subagentSessions.keys where key.hasPrefix(threadId + "/") { subagentSessions[key] = nil }
    }

    // MARK: Selection and sessions

    func select(_ threadId: String?) {
        selection = threadId
        openProjectId = nil
        stopShowingSubagent()
        guard let threadId else { return }
        let session = session(for: threadId)
        if session.state == .idle || session.state.isFailed {
            session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
        }
        if let thread = threads[threadId], thread.needsYou || thread.lastSeq > thread.lastSeenSeq {
            scheduleMarkSeen(threadId)
        }
    }

    /// Opens a thread from a chip in a reply, showing the sidebar list it's
    /// in (Archive or Hibernating for one that's put away).
    func openThread(_ threadId: String) {
        guard let thread = threads[threadId] else { return }
        if thread.isArchived {
            if sidebarMode != .archive { showArchive() }
        } else if let until = thread.snoozedUntil, until > Date() {
            sidebarMode = .snoozed
        } else {
            sidebarMode = .inbox
        }
        select(threadId)
    }

    /// Shows a sub-agent's transcript. Its thread becomes the selection.
    func selectSubagent(threadId: String, subagentId: String) {
        let ref = SubagentRef(threadId: threadId, subagentId: subagentId)
        if selection != threadId { select(threadId) }
        subagentSelection = ref
        let session = subagentSession(for: ref)
        if session.state == .idle || session.state.isFailed {
            session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
        } else {
            session.refreshSubagent()
        }
        pollSubagent(ref)
    }

    func subagentSession(for ref: SubagentRef) -> ThreadSession {
        if let existing = subagentSessions[ref.key] {
            existing.lastUsed = Date()
            return existing
        }
        let session = ThreadSession(threadId: ref.threadId, subagentId: ref.subagentId, app: self)
        subagentSessions[ref.key] = session
        // Old ones go; reading them again is cheap.
        if subagentSessions.count > 6, let oldest = subagentSessions.filter({ $0.key != ref.key }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            subagentSessions[oldest.key] = nil
        }
        return session
    }

    var selectedSubagent: Subagent? {
        guard let ref = subagentSelection else { return nil }
        return threads[ref.threadId]?.subagents.first { $0.id == ref.subagentId }
    }

    private func stopShowingSubagent() {
        subagentSelection = nil
        subagentPoll?.cancel()
        subagentPoll = nil
    }

    /// thread.updated says when a sub-agent has done something, but a
    /// thinking step doesn't change its summary, so while it runs its
    /// transcript is also read every 3 s. Once it has finished, one last
    /// read picks up its reply and the polling stops.
    private func pollSubagent(_ ref: SubagentRef) {
        subagentPoll?.cancel()
        subagentPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.subagentSelection == ref else { return }
                let running = self.selectedSubagent?.isRunning ?? false
                self.subagentSessions[ref.key]?.refreshSubagent()
                if !running { return }
            }
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

    /// A thread's session if it's open already, without opening one.
    func loadedSession(_ threadId: String) -> ThreadSession? { sessions[threadId] }

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
            guard !Task.isCancelled, let client, let thread = threads[threadId], isLooking, selection == threadId, subagentSelection == nil else { return }
            if let updated = try? await client.markSeen(threadId: threadId, seq: thread.lastSeq) {
                threads[threadId] = updated
            }
        }
    }

    func appBecameActive() {
        if subagentSelection == nil, let selection, let thread = threads[selection], thread.needsYou { scheduleMarkSeen(selection) }
    }

    // MARK: Thread actions

    func newThread() {
        selection = nil
        openProjectId = nil
        stopShowingSubagent()
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
            let account = newThreadAccountId
            let provider = provider(ofAccount: account)
            let request = NewThreadRequest(
                text: trimmed, images: draft.images, cwd: newThreadCwd ?? defaults.cwd, accountId: account,
                model: lastModels[provider], effort: lastEfforts[provider], permissionMode: newThreadAsk ? .ask : .full
            )
            Task {
                do {
                    let thread = try await client.createThread(request)
                    rememberLastAccount(account)
                    // The folder, "Ask before edits" and a picked account
                    // were for this thread; the next one starts from the
                    // defaults again, on whichever account then has the
                    // most room. The model and effort stick.
                    newThreadCwd = nil
                    newThreadAsk = false
                    newThreadAccount = nil
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

    /// Hibernate until the runner next starts. Offered while a restart is
    /// waiting for threads: one that's holding it up can go away now (its
    /// turn stops, so the restart can go ahead) and come back after.
    func snoozeUntilRestart(_ threadId: String? = nil) {
        guard let threadId = threadId ?? selection else { return }
        let next = neighbour(of: threadId)
        update(threadId, ThreadUpdate(snoozeUntilRestart: true))
        if selection == threadId { select(next) }
    }

    /// A runner restart is waiting for threads to finish.
    var restartPending: Bool {
        if case .pending = restart.phase { return true }
        return false
    }

    func unsnooze(_ threadId: String) {
        update(threadId, ThreadUpdate(snoozedUntil: .some(nil)))
    }

    func setPermission(_ threadId: String, ask: Bool) {
        update(threadId, ThreadUpdate(permissionMode: ask ? .ask : .full))
    }

    /// A model or effort picked on a thread is also what the next new
    /// thread starts on: the picker has no default row, it remembers.
    func setModel(_ threadId: String, _ model: String?) {
        remember(model: model, provider: threads[threadId]?.provider ?? "claude")
        update(threadId, ThreadUpdate(model: .some(model)))
    }

    func setEffort(_ threadId: String, _ effort: String?) {
        remember(effort: effort, provider: threads[threadId]?.provider ?? "claude")
        update(threadId, ThreadUpdate(effort: .some(effort)))
    }

    /// Keeps a last-picked value across launches; nil (the default) clears it.
    private static func remember(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    func setAccount(_ threadId: String, _ accountId: String) {
        rememberLastAccount(accountId)
        update(threadId, ThreadUpdate(accountId: accountId))
    }

    /// A model picked from another provider's column: the account and the
    /// model in one `threads.update`, so they can't arrive in the wrong
    /// order (two calls from two tasks could, and the pick was lost), and
    /// the model remembered under the provider it was picked from, not the
    /// one the thread was on. The provider's remembered effort goes too,
    /// since the runner resets effort on a provider change.
    func moveThread(_ threadId: String, toAccount accountId: String, model: String?) {
        let provider = provider(ofAccount: accountId)
        rememberLastAccount(accountId)
        remember(model: model, provider: provider)
        var change = ThreadUpdate(accountId: accountId, model: .some(model))
        if let effort = lastEfforts[provider] { change.effort = .some(effort) }
        update(threadId, change)
    }

    /// The last account used, overall (what `pickAccount` starts from) and
    /// per provider (which account another provider's column moves to).
    func rememberLastAccount(_ accountId: String) {
        UserDefaults.standard.set(accountId, forKey: Self.lastAccountKey)
        UserDefaults.standard.set(accountId, forKey: Self.memoryKey(Self.lastAccountKey, provider: provider(ofAccount: accountId)) + ".byProvider")
    }

    func lastAccountId(provider: String) -> String? {
        UserDefaults.standard.string(forKey: Self.memoryKey(Self.lastAccountKey, provider: provider) + ".byProvider")
    }

    /// The account a pick in a provider's column moves to: that provider's
    /// account with the most room (`pickAccount` over its accounts alone,
    /// from the last one used there), never a noted, blocked or nearly
    /// empty one while a better one exists; the provider's first account
    /// when nothing is known.
    func accountForProvider(_ provider: String) -> String? {
        let own = accounts.filter { $0.provider == provider }
        return AccountUsageText.pickAccount(own, lastUsedId: lastAccountId(provider: provider)) ?? own.first?.id
    }

    private func noteFailedAccounts(from old: [String: ThreadSummary]) {
        for (id, thread) in threads {
            let before = old[id]
            if thread.status == .error {
                if before?.status != .error || failedOnAccount[id] == nil { failedOnAccount[id] = thread.accountId }
            } else if failedOnAccount[id] != nil {
                failedOnAccount[id] = nil
            }
        }
        for id in failedOnAccount.keys where threads[id] == nil { failedOnAccount[id] = nil }
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
            // A CLI update under way (a spinner), or one that failed, which
            // stays until it's dismissed.
            if let cli = cliBanner {
                return Banner(style: .quiet, icon: cli.failedKey == nil ? nil : "exclamationmark.triangle", text: cli.text, dismissKey: cli.failedKey)
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

    // MARK: Dock

    /// The Dock badge is the number of threads that need you (DockBadge).
    /// Scripted runs (dev apps, perf and screenshot runs) show none, like
    /// notifications.
    private func refreshDockBadge() {
        guard notificationsEnabled else { return }
        let label = DockBadge.label(for: threads.values, now: now)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: Panels

    /// Whether the pane is beside this thread's transcript: when the folder
    /// gives it panels or patches (the Patches tab shows those).
    func showsPanels(for thread: ThreadSummary) -> Bool { panelsShown && (!thread.panels.isEmpty || !thread.patches.isEmpty) }

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
    /// A failed CLI update: the line has a Dismiss button, which forgets it.
    var dismissKey: String?
}

private extension RunnerRestart.Phase {
    var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }
}
