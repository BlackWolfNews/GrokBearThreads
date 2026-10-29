import AppKit
import BearDock
import Observation
import ThreadbearCore

/// The view picked in the activity bar. Hibernating and Archive were views
/// too, until they became sections of the inbox (29 Oct).
enum SidebarMode: Equatable {
    case inbox, scheduled, projects, librarian
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

/// One of Mike's messages being edited in the composer.
struct MessageEdit: Equatable {
    var seq: Int
    /// The draft the box held before, put back once the edit is sent or
    /// cancelled.
    var before: Draft
    /// The edit has gone to the runner and it hasn't answered yet.
    var sending = false
}

/// The answers picked on a thread's open card (ask index to option index),
/// and which card they're for.
struct AskPicks: Equatable {
    var asksSeq: Int
    var picks: [Int: Int]
}

/// App state: the runner connection, the thread list, the selection and the
/// open thread sessions. Holds no agent state of its own.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var connection: ConnectionState = .connecting
    /// A `threads.create` from the new-thread composer hasn't come back:
    /// its draft stays in the box, greyed and locked, with a spinner for
    /// Send, so the click visibly did something however slow the runner is.
    var creatingThread = false
    /// How long a thread may sit idle with one of Mike's messages still
    /// queued before the app gives up on it showing.
    static let queuedGrace: Double = 10
    @ObservationIgnored private var queuedChecks: Set<String> = []
    var runnerVersion = ""
    var accounts: [Account] = []
    var defaults = RunnerDefaults(cwd: NSString("~/dev/me/misc").expandingTildeInPath, accountId: "claude-main")
    /// The thread whose title is a field in the header just now (Rename,
    /// or a click on the title).
    var renamingThread: String?
    /// Threads whose sidebar rows are sliding off on their way to the
    /// archive, as a swiped row does (Mike asked 29 Oct): from the archive
    /// button, ⌘E, the done card, or an agent or the phone archiving it.
    /// `ThreadRowView` slides a row off while its thread is in here.
    private(set) var slidingOff: Set<String> = []
    /// What the runner said about a thread archived elsewhere, held back
    /// while its row slides off, so the row's still there to slide.
    @ObservationIgnored private var heldWhileSliding: [String: ThreadSummary] = [:]
    var threads: [String: ThreadSummary] = [:] {
        didSet {
            threadsVersion &+= 1
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
    // These four are where the window is; a change to any of them is a
    // step in the back/forward history (Navigation.swift).
    var selection: String? {
        didSet {
            if selection != oldValue {
                noteNavigation()
                mainContextChanged()
                // Back and forward set this without select().
                servePanelRequest()
                tidyRemoteClients()
            }
        }
    }
    /// A sub-agent's transcript is showing instead of its thread's. The
    /// thread stays `selection`, so the sidebar keeps its sub-agents listed
    /// and the toolbar still names it.
    var subagentSelection: SubagentRef? {
        didSet { if subagentSelection != oldValue { noteNavigation() } }
    }
    var sidebarMode: SidebarMode = .inbox {
        didSet {
            if sidebarMode != oldValue { noteNavigation() }
            if sidebarMode != .projects { showsProjectsHome = false }
            if sidebarMode != .librarian { showsLibrarianHome = false }
            if sidebarMode != .scheduled { showsScheduledHome = false }
        }
    }
    /// Back and forward (⌘[ and ⌘], or the mouse's side buttons).
    var history = NavigationHistory<NavigationPlace>()
    @ObservationIgnored var navigationPending = false
    var archiveQuery = ""
    /// Archived threads are in `threads` (the first list includes them, for
    /// the Archive view's count).
    var archiveLoaded = false
    var errorMessage: String?
    /// Bumped to put the cursor in a composer, by its draft key (a thread's
    /// id, or "new"): with threads open in several panels, only that one's.
    var focusRequests: [String: Int] = [:]
    var now = Date()
    var drafts: [String: Draft] = [:]
    /// Messages being edited, by thread id: the seq of the message the
    /// composer's draft will replace (docs/protocol.md, "Editing a
    /// message"), and whatever was in the box before, to put back after.
    var editing: [String: MessageEdit] = [:]
    /// The answers Mike has picked on each thread's open card of asks, by
    /// thread id, waiting in the composer to go with his next message.
    /// Ones for an older card count as none.
    var askPicks: [String: AskPicks] = [:]
    @ObservationIgnored var reviewWindows: [String: ReviewWindowController] = [:]
    /// The review open in the dock's Review panel (WindowDock.review), if
    /// any. A review popped out into its own window leaves it.
    var reviewPanel: ReviewSession?
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
    /// With pools, a pick here pins the new thread to that login.
    var newThreadAccount: String?
    /// The runner's pools (docs/pools-plan.md), in its order. Replaced whole
    /// by `pools.updated`.
    var pools: [Pool] = []
    /// The runner has pools. False for an older one, which sends none in
    /// hello: then the composer keeps its account chip and the picker's
    /// rail lists providers, as before.
    var poolsSupported = false
    /// The pool Mike picked for the next new thread, for that draft only.
    /// With none, the folder's pool or the one he last picked
    /// (`newThreadPoolId`).
    var newThreadPool: String?
    /// The provider whose model Mike picked for the draft in a mixed pool.
    var newThreadProvider: String?
    /// Why the last `pools.save` didn't take, for Settings › Pools.
    var poolsError: String?
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
    /// Tokens by the hour and limit readings over time (`usage.stats`),
    /// for the Usage panel. Asked for while the panel is open.
    var usageStats: UsageStats?
    /// Nil until asked; false for a runner without `usage.stats`.
    var usageStatsSupported: Bool?
    /// Update failures Mike has dismissed, by "<provider>|<finishedAt>",
    /// so the line under the toolbar stays gone for that failure.
    var dismissedCliFailures: Set<String> = []
    /// Bumped to open the composer's model picker from the automation
    /// (`composer-menu` with `show`), the way a click on the chip does.
    var modelPickerRequest = 0
    /// The same for the account picker.
    var accountPickerRequest = 0
    /// Every schedule, in the runner's order (soonest first, then the
    /// paused and finished ones). Replaced whole by `schedules.updated`.
    var schedules: [Schedule] = [] {
        didSet { schedulesVersion &+= 1 }
    }
    /// The runner knows about schedules: an older one answers
    /// `schedules.list` with -32601, and then the sidebar has no Scheduled row.
    var schedulesSupported = false
    /// The runners a schedule can run on (`runners.list`), this one first.
    /// Empty from a runner before step 6, or before it answers: then
    /// there's no choice to offer and every schedule is this runner's.
    var runners: [RunnerInfo] = []
    /// Other runners, from this one (docs/protocol.md, "Other runners'
    /// threads"): their names, icons, whether they're online and how to
    /// reach them. Their threads are in `threads`, marked with `runnerId`
    /// (RemoteRunners.swift).
    var remoteRunners: [RemoteRunner] = []
    /// The last `remoteThreads` list, kept to put the sidebar table's rows
    /// back once a runner's own connection closes.
    @ObservationIgnored var remoteIndex = RemoteThreads()
    /// Other runners' threads whose summary came from their own runner's
    /// connection, which is fuller and fresher than the sidebar table's
    /// row, until that connection closes.
    @ObservationIgnored var liveRemote: Set<String> = []
    /// One connection per other runner, made when one of its threads is
    /// opened.
    @ObservationIgnored let remoteClients = RemoteClients(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    @ObservationIgnored var remoteTidy: Task<Void, Never>?
    /// Every project, archived ones too, in the runner's order (newest
    /// activity first). Replaced whole by `projects.updated`.
    var projects: [Project] = [] {
        didSet { projectsVersion &+= 1 }
    }
    /// The runner knows about projects: an older one answers
    /// `projects.list` with -32601, and then the activity bar has no
    /// Projects or Librarian button and threads show no project chips.
    var projectsSupported = false
    /// What the librarian is doing, once `librarian.status` has answered;
    /// replaced by `librarian.updated`.
    var librarian: LibrarianStatus?
    /// The Connectors gateway's services (docs/protocol.md, "Connectors"),
    /// once `connectors.status` has answered; replaced by
    /// `connectors.updated`. Nil from a runner that doesn't know about it,
    /// and then the activity bar has no Connectors icon.
    var connectors: ConnectorsStatus?
    /// The project page showing in the detail area instead of the thread.
    /// Selecting a thread (or a new one) closes it.
    var openProjectId: String? {
        didSet {
            if openProjectId != oldValue {
                noteNavigation()
                mainContextChanged()
            }
        }
    }
    /// The Projects page (a card per project) in the detail area: what
    /// clicking Projects in the activity bar opens. Picking a thread or a
    /// project, or leaving the Projects view, closes it.
    var showsProjectsHome = false {
        didSet {
            if showsProjectsHome != oldValue {
                noteNavigation()
                mainContextChanged()
            }
        }
    }
    /// The Librarian's page (what it is, what it's up to and its numbers)
    /// in the detail area, from the activity bar's Librarian. Closes the
    /// same ways as the Projects page.
    var showsLibrarianHome = false {
        didSet {
            if showsLibrarianHome != oldValue {
                noteNavigation()
                mainContextChanged()
            }
        }
    }
    /// The Scheduled page (what schedules are, what's coming up and their
    /// numbers), from the activity bar's Scheduled. Closes the same ways.
    var showsScheduledHome = false {
        didSet {
            if showsScheduledHome != oldValue {
                noteNavigation()
                mainContextChanged()
            }
        }
    }
    /// One of those pages is in the detail area, not the selected thread.
    var showsHomePage: Bool { showsProjectsHome || showsLibrarianHome || showsScheduledHome }
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
    /// Settings › Phone & browser (DevicesModel.swift): the backend's list
    /// of paired phones and browsers as the runner last gave it, the
    /// website's root, or why nothing can pair. Never a token.
    var devices: [Device] = []
    var devicesSite: String?
    var devicesReason: String?
    var devicesError: String?
    var devicesUnsupported = false
    var devicesLoaded = false
    var devicesLoading = false
    /// Bumped by the automation to show the pairing code, for screenshots.
    var pairRequest = 0
    /// The schedule editor sheet, when it's open (ScheduleEditor).
    var scheduleEditor: ScheduleEditorState?
    /// A sidebar row drawn as if the pointer were over it, so the screenshot
    /// run can show the hover buttons without moving the mouse.
    var hoverOverride: String?
    /// The window's panels and where they are (WindowDock), saved as Mike
    /// moves them.
    @ObservationIgnored let dock = WindowDock.makeController()
    /// Panels opened as tabs beside the main panel for what it's showing
    /// (a review, so far). They close when the main panel moves on to
    /// something else, unless Mike has dragged them out of its group by
    /// then, which keeps them (`dockChanged`).
    @ObservationIgnored var mainTabs: Set<PanelID> = []
    /// The transcripts of threads open in panels of their own, by thread id.
    /// The main panel's is `transcript`.
    @ObservationIgnored var panelTranscripts: [String: TranscriptController] = [:]
    /// The pane sections open when Hide Panels closed them, for Show Panels.
    @ObservationIgnored var hiddenPanes: [PanelID] = []
    /// Whether any pane section (Highlights, a panel, Patches) is open in
    /// the dock. Setting it closes them all, or opens again the ones Hide
    /// Panels closed (Highlights if none).
    var panelsShown: Bool {
        get { !openPanes.isEmpty }
        set {
            if newValue {
                guard openPanes.isEmpty else { return }
                for id in hiddenPanes.isEmpty ? [PaneSection.highlightsId] : hiddenPanes {
                    showPane(PaneSection(id: id))
                }
            } else {
                hiddenPanes = openPanes
                for id in hiddenPanes { dock.close(id) }
            }
        }
    }
    /// Inbox sections folded away under their heading, remembered across
    /// launches (Mike asked 27 Oct). Hibernating and Archive start folded.
    var collapsedSections: Set<InboxSection> = AppModel.storedCollapsedSections() {
        didSet { UserDefaults.standard.set(collapsedSections.map(\.rawValue).sorted(), forKey: Self.collapsedSectionsKey) }
    }
    /// The Inbox section's order, from the sort menu on its heading,
    /// remembered across launches.
    var inboxOrder: InboxOrder = InboxOrder(rawValue: UserDefaults.standard.string(forKey: AppModel.inboxOrderKey) ?? "") ?? .needsYou {
        didSet { UserDefaults.standard.set(inboxOrder.rawValue, forKey: Self.inboxOrderKey) }
    }
    /// A thread's chosen pane section, as `PaneSection.id`.
    var panelChoice: [String: String] = [:]
    /// Each thread's highlights once `threads.highlights` has answered
    /// (PaneModel.swift). Only threads Mike has opened this session.
    var highlights: [String: ThreadHighlights] = [:]
    /// The runner answered `threads.highlights` with -32601: the section
    /// says so, and nothing asks again until the next connection.
    var highlightsUnsupported = false
    /// A file or page open in the pane in place of its section, per thread.
    var panePreview: [String: PanePreview] = [:]
    /// Each thread's Explain side conversation (ExplainModel.swift).
    var explainers: [String: ExplainSession] = [:]
    @ObservationIgnored var explainCount = 0
    @ObservationIgnored var highlightFetches: [String: Task<Void, Never>] = [:]
    /// Bumped by each request for a thread's highlights, so a change that
    /// lands while a fetch is out gets fetched again after it.
    @ObservationIgnored var highlightWanted: [String: Int] = [:]
    @ObservationIgnored var highlightAutoShow = HighlightAutoShow()
    /// The agents' show_panel requests shown this run (PanelRequestModel).
    @ObservationIgnored var panelRequestGate = PanelRequestGate()
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
    /// The website's root, from runner.status (nil while sync is off).
    private(set) var websiteURL: URL?
    /// The runner's own update (protocol "Runner updates"), for the rail's
    /// updates icon. Nil from a runner older than that.
    var runnerUpdates: RunnerUpdates?
    /// The little popover a right-click on the updates icon opens, for
    /// updating the app without the panel. On the model so a script can
    /// open it.
    var updatePopoverShown = false
    /// The thread whose share popover is open, if any. On the model so a
    /// script can open it.
    var sharePopoverThread: String?

    @ObservationIgnored private(set) var client: RPCClient?
    @ObservationIgnored private var sessions: [String: ThreadSession] = [:]
    /// Sub-agent transcripts, keyed by `SubagentRef.key`. A handful at most.
    @ObservationIgnored private var subagentSessions: [String: ThreadSession] = [:]
    @ObservationIgnored private var subagentPoll: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// By thread: the main panel's and those in panels of their own can
    /// be marked at once.
    @ObservationIgnored private var markSeenTasks: [String: Task<Void, Never>] = [:]
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
    /// The last pool Mike picked, and the provider he last picked a model
    /// of in each pool (a mixed one has two).
    static let lastPoolKey = "lastPoolId"
    static let lastPoolProvidersKey = "lastPoolProviders"
    /// Claude's keys keep their old names, so a model picked before Codex
    /// came along is still remembered; other providers add ".<provider>".
    static let lastModelKey = "lastModel"
    static let lastEffortKey = "lastEffort"
    static let memoryProviders = ["claude", "codex"]
    static let collapsedSectionsKey = "collapsedSections"
    /// Set once Hibernating and Archive have been folded the first time.
    /// They came after collapsedSections did, so a saved list without them
    /// can't tell "never seen" from "opened".
    static let putAwayFoldedKey = "putAwaySectionsFolded"

    static func storedCollapsedSections(_ defaults: UserDefaults = .standard) -> Set<InboxSection> {
        var sections = Set((defaults.stringArray(forKey: collapsedSectionsKey) ?? []).compactMap(InboxSection.init(rawValue:)))
        if !defaults.bool(forKey: putAwayFoldedKey) {
            sections.formUnion([.hibernating, .archived])
            defaults.set(sections.map(\.rawValue).sorted(), forKey: collapsedSectionsKey)
            defaults.set(true, forKey: putAwayFoldedKey)
        }
        return sections
    }
    static let inboxOrderKey = "inboxOrder"
    /// The error banner text shown for a connection problem, so it can be
    /// cleared when the connection comes back.
    @ObservationIgnored private var connectionErrorMessage: String?

    init() {
        // The dock saves its layout on every change (WindowDock); this
        // follows panels in and out of the main panel's group as well.
        let save = dock.onChange
        dock.onChange = { [weak self] layout in
            save?(layout)
            self?.dockChanged(layout)
        }
        wireRemoteClients()
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

    // Bumped on every change to these, for the memos below: cheaper than
    // comparing every thread.
    @ObservationIgnored private var threadsVersion = 0
    @ObservationIgnored private var schedulesVersion = 0
    @ObservationIgnored private var projectsVersion = 0
    private struct DerivedKey: Equatable {
        var threads: Int, other: Int, now: Date, order: InboxOrder?
    }
    @ObservationIgnored private var sectionsMemo: (key: DerivedKey, value: ThreadSections)?
    @ObservationIgnored private var projectSectionsMemo: (key: DerivedKey, value: ProjectSections)?

    // MARK: Derived

    /// Built once per change rather than once per reader. The activity
    /// bar's badge, the inbox list and the projects views all read these, and
    /// every thread.updated from a running thread used to rebuild them for
    /// each one, copying and sorting every thread each time: most of what an
    /// update cost the main thread.
    var sections: ThreadSections {
        // Read through the observed properties every time, memo or not, so
        // a view reading this still redraws when any of them changes.
        let (threads, now, schedules, order) = (threads, now, schedules, inboxOrder)
        let key = DerivedKey(threads: threadsVersion, other: schedulesVersion, now: now, order: order)
        if let memo = sectionsMemo, memo.key == key { return memo.value }
        let built = ThreadSections.build(threads.values, now: now, wakes: ThreadSections.wakes(schedules), order: order)
        sectionsMemo = (key, built)
        return built
    }

    var projectSections: ProjectSections {
        let (threads, now, projects) = (threads, now, projects)
        let key = DerivedKey(threads: threadsVersion, other: projectsVersion, now: now, order: nil)
        if let memo = projectSectionsMemo, memo.key == key { return memo.value }
        let built = ProjectSections.build(projects: projects, threads: threads.values, now: now)
        projectSectionsMemo = (key, built)
        return built
    }
    /// The schedule due to message each thread soonest, for the Waiting section.
    var wakes: [String: Schedule] { ThreadSections.wakes(schedules) }
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
        if let newThreadAccount { return newThreadAccount }
        // With pools, the login the runner would pick in the new thread's
        // pool, so the picker lists that provider's models.
        if let poolId = newThreadPoolId, let pool = pool(poolId) {
            let provider = newThreadProvider(in: poolId)
            if let login = Pools.pickLogin(pool, accounts: accounts, provider: provider, current: lastAccountId(provider: provider)) { return login }
        }
        return AccountUsageText.pickAccount(accounts, lastUsedId: lastAccountId) ?? lastAccountId
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
                let build = BuildInfo.read(bundle: Bundle.main.bundleURL).flatMap { $0.appTree.isEmpty ? nil : (commit: $0.commit, short: $0.short, tree: $0.appTree) }
                let hello = try await client.hello(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", build: build)
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
                // An older runner sends no pools; the app then works as it
                // did before them.
                pools = hello.pools ?? []
                poolsSupported = hello.pools != nil
                if hello.clis.isEmpty { loadClis() }
                // Maybe a newer runner than last time.
                highlightsUnsupported = false
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
                // Other runners' threads aren't this runner's to list.
                for (id, thread) in threads where thread.isRemote && fresh[id] == nil { fresh[id] = thread }
                threads = fresh
                threadsLoaded = true
                archiveLoaded = true
                onThreadsLoaded?()
                servePanelRequest()
                loadSchedules()
                loadRunners()
                loadRemoteThreads()
                loadProjects()
                loadConnectors()
                loadSettings()
                // Other runners' threads come back with their own connection.
                for session in sessions.values where session.state == .loaded && !isRemote(session.threadId) {
                    await session.subscribe()
                }
                for session in sessions.values where session.state != .loaded && !isRemote(session.threadId) {
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
                for session in sessions.values where !isRemote(session.threadId) { session.connectionLost() }
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
            case .poolsUpdated(let list):
                pools = list
                poolsSupported = true
            case .clisUpdated(let list):
                clis = list
                clisSupported = true
            case .schedulesUpdated(let list):
                schedules = list
                schedulesSupported = true
            case .remoteThreadsUpdated(let remote):
                receive(remote: remote)
            case .projectsUpdated(let list):
                receive(projects: list)
            case .librarianUpdated(let status):
                librarian = status
                projectsSupported = true
            case .connectorsUpdated(let status):
                connectors = status
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
    func receiveForTesting(_ thread: ThreadSummary) { receive(thread) }
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

    func receive(_ thread: ThreadSummary) {
        if heldWhileSliding[thread.id] != nil {
            heldWhileSliding[thread.id] = thread
            return
        }
        // Archived somewhere else: slide its row off first, then let it go.
        // Not one archived here, which is already sliding (`archive`).
        if thread.isArchived, threads[thread.id]?.isArchived == false, !slidingOff.contains(thread.id) {
            heldWhileSliding[thread.id] = thread
            slideOff(thread.id)
            Task {
                try? await Task.sleep(for: Self.slideTime)
                if let held = heldWhileSliding.removeValue(forKey: thread.id) { apply(held) }
                await endSlide(thread.id)
            }
            return
        }
        apply(thread)
    }

    private func apply(_ thread: ThreadSummary) {
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
        checkQueued(thread.id)
        let becameNeedy = thread.needsYou && previous?.needsYou != true
        let showing = isLooking && isShowing(thread.id)
        // Not for another runner's threads: notifications are low-key,
        // and that Mac's app says so there.
        if becameNeedy && !showing && notificationsEnabled && !thread.isRemote {
            Notifier.post(thread: thread)
        }
        if showing && thread.lastSeq > thread.lastSeenSeq && thread.status != .waiting {
            scheduleMarkSeen(thread.id)
        }
        if thread.panelRequest != nil, thread.id == selection { servePanelRequest() }
    }

    /// A thread deleted on the runner (by an agent's delete_thread, or `tb
    /// delete`) disappears from every list straight away.
    func forget(_ threadId: String) {
        let panel = WindowDock.threadPanel(threadId)
        if dock.layout.contains(panel) { dock.close(panel) }
        threads[threadId] = nil
        drafts[threadId] = nil
        if let session = sessions.removeValue(forKey: threadId) { session.unsubscribe() }
        if selection == threadId { selection = nil }
        if subagentSelection?.threadId == threadId { subagentSelection = nil }
        for key in subagentSessions.keys where key.hasPrefix(threadId + "/") { subagentSessions[key] = nil }
    }

    // MARK: Selection and sessions

    func select(_ threadId: String?) {
        // A thread open in a panel of its own is shown there: its panel
        // comes to the front and the main panel stays as it is.
        if let threadId, dock.layout.contains(WindowDock.threadPanel(threadId)) {
            dock.show(WindowDock.threadPanel(threadId))
            return
        }
        selection = threadId
        openProjectId = nil
        showsProjectsHome = false
        showsLibrarianHome = false
        showsScheduledHome = false
        stopShowingSubagent()
        guard let threadId else { return }
        let session = session(for: threadId)
        if session.state == .idle || session.state.isFailed {
            session.open(width: transcript.width > 0 ? transcript.width : transcript.currentTableWidth)
        } else if isRemote(threadId), !session.subscribed {
            // Its runner's connection closed while it was away.
            reconnectRemote(for: threadId)
        }
        if let thread = threads[threadId], thread.needsYou || thread.lastSeq > thread.lastSeenSeq {
            scheduleMarkSeen(threadId)
        }
        servePanelRequest()
    }

    /// Opens a thread from a chip in a reply, showing it in the inbox
    /// (with Archive or Hibernating unfolded for one that's put away).
    func openThread(_ threadId: String) {
        guard let thread = threads[threadId] else { return }
        if thread.isArchived {
            showArchive()
        } else if thread.isSnoozed(at: Date()) {
            showHibernating()
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

    /// Every open session, for RemoteRunners.swift.
    var openSessions: [ThreadSession] { Array(sessions.values) }

    /// Lets a session go, so the thread loads afresh next time it's opened.
    func dropSession(_ threadId: String) {
        sessions.removeValue(forKey: threadId)?.unsubscribe()
    }

    private func evictSessions() {
        guard sessions.count > Self.maxSessions else { return }
        let victims = sessions.values
            .filter { $0.threadId != selection && panelTranscripts[$0.threadId] == nil }
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(sessions.count - Self.maxSessions)
        for victim in victims {
            victim.unsubscribe()
            sessions[victim.threadId] = nil
        }
    }

    func focusComposer(_ draftKey: String) {
        focusRequests[draftKey, default: 0] += 1
    }

    /// The thread's transcript is in front of Mike: in the main panel, or
    /// its own panel's tab is the one showing.
    func isShowing(_ threadId: String) -> Bool {
        (selection == threadId && subagentSelection == nil) || dock.isShowing(WindowDock.threadPanel(threadId))
    }

    func scheduleMarkSeen(_ threadId: String) {
        markSeenTasks[threadId]?.cancel()
        markSeenTasks[threadId] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let client = client(for: threadId), let thread = threads[threadId], isLooking, isShowing(threadId) else { return }
            if let updated = try? await client.markSeen(threadId: threadId, seq: thread.lastSeq) {
                threads[threadId] = updated
            }
        }
    }

    func appBecameActive() {
        if subagentSelection == nil, let selection, let thread = threads[selection], thread.needsYou { scheduleMarkSeen(selection) }
        servePanelRequest()
    }

    // MARK: Thread actions

    func newThread() {
        selection = nil
        openProjectId = nil
        showsProjectsHome = false
        showsLibrarianHome = false
        showsScheduledHome = false
        stopShowingSubagent()
        sidebarMode = .inbox
        focusComposer("new")
    }

    /// The answers picked on the thread's open card (ask index to option
    /// index), none for a card he hasn't touched.
    func picks(for thread: ThreadSummary) -> [Int: Int] {
        guard Decisions.isOpen(thread), let seq = thread.asksSeq, let mine = askPicks[thread.id], mine.asksSeq == seq else { return [:] }
        return mine.picks
    }

    /// Picks option `option` on ask `ask` of the open card, or unpicks it
    /// when it's already the pick. It waits in the composer as a chip and
    /// goes with whatever he sends next.
    func pickAnswer(thread: ThreadSummary, ask: Int, option: Int) {
        guard Decisions.isOpen(thread), let seq = thread.asksSeq else { return }
        var picks = picks(for: thread)
        // What he writes can only answer one ask, so "Something else" moves.
        if option == Decisions.ownAnswer { picks = picks.filter { $0.value != Decisions.ownAnswer || $0.key == ask } }
        picks[ask] = picks[ask] == option ? nil : option
        setPicks(picks, seq: seq, threadId: thread.id)
        focusComposer(thread.id)
    }

    private func setPicks(_ picks: [Int: Int], seq: Int, threadId: String) {
        askPicks[threadId] = picks.isEmpty ? nil : AskPicks(asksSeq: seq, picks: picks)
        sessions[threadId]?.setAskPicks(seq: seq, picks: picks)
    }

    /// Puts one of Mike's messages in the thread's composer to edit: sending
    /// it then replaces that message and carries on from there.
    func startEditing(threadId: String, seq: Int, text: String, images: [ImageRef]) {
        let before = editing[threadId]?.before ?? drafts[threadId] ?? Draft()
        editing[threadId] = MessageEdit(seq: seq, before: before)
        drafts[threadId] = Draft(text: text, images: images)
        focusComposer(threadId)
    }

    /// Leaves the edit: the box gets back what was in it before.
    func cancelEditing(threadId: String) {
        guard let edit = editing.removeValue(forKey: threadId) else { return }
        drafts[threadId] = edit.before.text.isEmpty && edit.before.images.isEmpty ? nil : edit.before
    }

    /// Sends the edited message. The box keeps it, marked as sending,
    /// until the runner has started the new turn; an error leaves it there
    /// to try again.
    private func sendEdit(threadId: String, edit: MessageEdit) {
        let draft = drafts[threadId] ?? Draft()
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.images.isEmpty, !edit.sending else { return }
        guard let client = client(for: threadId), isRemote(threadId) || connection == .connected else {
            showConnectionError(notConnectedText(threadId, "the edit wasn't sent"))
            return
        }
        ActivityRecorder.shared.sent(threadId: threadId, images: draft.images.count, answers: 0, edit: true)
        editing[threadId]?.sending = true
        Task {
            do {
                try await client.editMessage(threadId: threadId, seq: edit.seq, text: text, images: draft.images)
                editing[threadId] = nil
                drafts[threadId] = edit.before.text.isEmpty && edit.before.images.isEmpty ? nil : edit.before
            } catch {
                editing[threadId]?.sending = false
                show(error)
            }
        }
    }

    /// Sends the draft for `threadId` (or starts a new thread with the "new"
    /// draft), with any answers picked on the open card. In a thread the
    /// box empties straight away and the message shows at the end of the
    /// transcript, dimmed, until the runner shows it (a busy Mac can keep
    /// the runner from answering for many seconds); the text, images and
    /// picks go back if the runner doesn't take them. A new thread's
    /// draft stays in the box, greyed, with a spinner for Send, until the
    /// thread exists. While disconnected nothing is touched at all.
    func send(threadId: String?) {
        let key = threadId ?? "new"
        if let threadId, let edit = editing[threadId] {
            sendEdit(threadId: threadId, edit: edit)
            return
        }
        let draft = drafts[key] ?? Draft()
        // Answers picked on the open card go first, each question then its
        // answer, and his own words after them (Decisions.message).
        let thread = threadId.flatMap { threads[$0] }
        // self. so Swift 6.3 (Xcode 26) doesn't read picks as the variable being declared.
        let picks = thread.map { self.picks(for: $0) } ?? [:]
        let asks = thread?.asks ?? []
        let answers = Decisions.answers(asks: asks, picks: picks, written: draft.text).map(\.answer)
        let trimmed = answers.isEmpty
            ? draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : Decisions.message(asks: asks, picks: picks, extra: draft.text)
        guard !trimmed.isEmpty || !draft.images.isEmpty else { return }
        // A second Return while the first new thread is still being made.
        if threadId == nil, creatingThread { return }
        guard let client = client(for: threadId), threadId.map(isRemote) == true || connection == .connected else {
            showConnectionError(notConnectedText(threadId, "that wasn't sent"))
            return
        }
        ActivityRecorder.shared.sent(threadId: threadId, images: draft.images.count, answers: answers.count)
        if let threadId {
            drafts[key] = nil
            let seq = thread?.asksSeq
            if let seq, !answers.isEmpty { setPicks([:], seq: seq, threadId: threadId) }
            let pendingId = UUID().uuidString
            // The thread's own session, open already as its composer is
            // showing; kept by the Task, so a failure finds it.
            let session: ThreadSession? = self.session(for: threadId)
            session?.addPending(id: pendingId, text: trimmed, images: draft.images, answers: answers, summarySeq: thread?.lastSeq ?? 0)
            Task {
                do {
                    try await client.send(threadId: threadId, text: trimmed, images: draft.images, answers: answers)
                    // Taken but not shown: it's queued behind the running
                    // turn. Its user.message usually comes just before this
                    // reply, but is applied on the next frame, so wait a
                    // moment rather than flash the clock on every send.
                    try? await Task.sleep(for: .milliseconds(600))
                    session?.markQueued(pendingId)
                    checkQueued(threadId)
                } catch {
                    session?.removePending(pendingId)
                    restoreDraft(draft, key: key)
                    if let seq, !answers.isEmpty { setPicks(picks, seq: seq, threadId: threadId) }
                    show(error)
                }
            }
        } else {
            let account = newThreadAccountId
            let request = newThreadRequest(text: trimmed, images: draft.images)
            creatingThread = true
            Task {
                defer { creatingThread = false }
                do {
                    let thread = try await client.createThread(request)
                    // Only what was sent goes; the box was locked meanwhile.
                    if drafts[key] == draft { drafts[key] = nil }
                    // In a pool the runner picked the login; that's the one
                    // that counts as used.
                    rememberLastAccount(request.poolId == nil ? account : thread.accountId)
                    // The folder, "Ask before edits" and a picked account
                    // or pool were for this thread; the next one starts
                    // from the defaults again, on whichever account then
                    // has the most room. The model and effort stick.
                    newThreadCwd = nil
                    newThreadAsk = false
                    newThreadAccount = nil
                    newThreadPool = nil
                    newThreadProvider = nil
                    threads[thread.id] = thread
                    select(thread.id)
                } catch {
                    // The draft never left the box.
                    show(error)
                }
            }
        }
    }

    /// Updates panel, From Mike: a new thread in the repo the runner
    /// follows that merges Mike's release in (docs/bringing-in-updates.md),
    /// on the composer's account or pool and model.
    func bringInUpstream(_ upstream: RunnerUpdates.Upstream) {
        guard let client, let release = upstream.release, !creatingThread else { return }
        var request = newThreadRequest(text: UpdatesText.bringInPrompt(release), images: [])
        request.cwd = upstream.checkout ?? AppUpdater.shared.running?.checkout ?? request.cwd
        request.permissionMode = .full
        request.title = "Bring in Mike's release \(UpdatesText.releaseDate(release.tag))"
        creatingThread = true
        Task {
            defer { creatingThread = false }
            do {
                let thread = try await client.createThread(request)
                threads[thread.id] = thread
                select(thread.id)
            } catch {
                show(error)
            }
        }
    }

    /// A queued message starts its own turn once the thread is free, so
    /// one still queued after the thread has sat idle a while was lost on
    /// the way (a disconnect clears them anyway): it goes rather than stay
    /// at the end of the transcript for good.
    private func checkQueued(_ threadId: String) {
        guard threads[threadId]?.status.isBusy == false, sessions[threadId]?.hasQueued == true,
              queuedChecks.insert(threadId).inserted else { return }
        Task {
            try? await Task.sleep(for: .seconds(Self.queuedGrace))
            queuedChecks.remove(threadId)
            if threads[threadId]?.status.isBusy == false { sessions[threadId]?.dropQueued() }
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
        guard let threadId = selection, let client = client(for: threadId) else { return }
        Task { try? await client.interrupt(threadId: threadId) }
    }

    /// Changes a thread on the runner. What can safely be guessed (archived,
    /// snoozed, permission, model, effort) shows at once
    /// (`ThreadUpdate.applied`), so the click does something however slow
    /// the runner is; its reply replaces the guess, and a failure puts back
    /// what was there unless something else has changed it since.
    func update(_ threadId: String, _ update: ThreadUpdate) {
        guard let client = client(for: threadId) else { return }
        let before = threads[threadId]
        let guess = before.map { update.applied(to: $0) }
        if let guess, guess != before { threads[threadId] = guess }
        Task {
            do {
                threads[threadId] = try await client.updateThread(threadId, update)
            } catch {
                if let before, let guess, threads[threadId] == guess { threads[threadId] = before }
                show(error)
            }
        }
    }

    /// Whether anyone with the link can read a thread on the website
    /// (protocol "Sharing"). The share popover shows a failure itself, so
    /// this throws rather than putting up the banner.
    func share(_ threadId: String, access: ThreadShare.Access, newLink: Bool = false) async throws {
        guard let client = client(for: threadId) else { throw RPCError.disconnected(nil) }
        threads[threadId] = try await client.share(threadId: threadId, access: access, newLink: newLink)
    }

    /// A shared thread's link on the website, while sync is on.
    func shareLink(_ share: ThreadShare) -> URL? {
        websiteURL?.appendingPathComponent("s").appendingPathComponent(share.slug)
    }

    /// Opens the thread if it isn't, and makes its title in the header a field.
    func startRenaming(_ threadId: String? = nil) {
        guard let threadId = threadId ?? selection, threads[threadId] != nil else { return }
        if selection != threadId { select(threadId) }
        renamingThread = threadId
    }

    /// Mike's own name for a thread, from the header. The runner keeps it:
    /// no model title or agent replaces it unless he asks (protocol
    /// `threads.update`, `titleBy`). Shown at once, put back if it fails.
    func rename(_ threadId: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client(for: threadId), let before = threads[threadId], !title.isEmpty, title != before.title else { return }
        threads[threadId]?.title = title
        Task {
            do {
                threads[threadId] = try await client.updateThread(threadId, ThreadUpdate(title: title))
            } catch {
                if threads[threadId]?.title == title { threads[threadId]?.title = before.title }
                show(error)
            }
        }
    }

    /// Archive (Mike calls it settling): leaves the inbox, stops its CLI.
    /// Its row slides off first, as a swiped one does;
    /// `slid` is a swipe that's already done that.
    func archive(_ threadId: String? = nil, slid: Bool = false) {
        guard let threadId = threadId ?? selection else { return }
        let next = neighbour(of: threadId)
        if selection == threadId { select(next) }
        if slid { return update(threadId, ThreadUpdate(archived: true)) }
        guard !slidingOff.contains(threadId) else { return }
        slideOff(threadId)
        Task {
            try? await Task.sleep(for: Self.slideTime)
            do {
                guard let client = client(for: threadId) else { throw RPCError.disconnected(nil) }
                threads[threadId] = try await client.updateThread(threadId, ThreadUpdate(archived: true))
                await endSlide(threadId)
            } catch {
                // Still in the inbox: bring the row back.
                slidingOff.remove(threadId)
                show(error)
            }
        }
    }

    /// As long as a swiped row takes to leave (`RowSwipeController`).
    static var slideTime: Duration { .milliseconds(Juice.reduceMotion ? 100 : 160) }

    /// The row animates it (`ThreadRowView`).
    private func slideOff(_ threadId: String) {
        slidingOff.insert(threadId)
    }

    /// The row's normally gone by now. If it's still drawn (a list that
    /// keeps archived threads), it springs back into place.
    private func endSlide(_ threadId: String) async {
        try? await Task.sleep(for: .milliseconds(600))
        slidingOff.remove(threadId)
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

    /// Hibernate until when Mike said, in his words. The runner puts it
    /// away straight off (its row says Thinking… until the time is worked
    /// out); if the model can't say, it comes back and the banner says why.
    func hibernateWhen(_ threadId: String, said: String) {
        guard let client = client(for: threadId) else { return }
        let next = neighbour(of: threadId)
        if selection == threadId { select(next) }
        Task {
            do {
                threads[threadId] = try await client.hibernateWhen(threadId: threadId, said: said)
            } catch {
                show(error)
            }
        }
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

    /// The inbox with its Archived section unfolded.
    func showArchive() {
        sidebarMode = .inbox
        collapsedSections.remove(.archived)
        loadArchive()
    }

    /// The inbox with its Hibernating section unfolded.
    func showHibernating() {
        sidebarMode = .inbox
        collapsedSections.remove(.hibernating)
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

    /// Images pasted or dropped somewhere other than the composer (a
    /// decision's box) go into the thread's draft, so they show in the
    /// composer's strip and go with the next send.
    func attachImages(_ urls: [URL], toDraft key: String) {
        guard !urls.isEmpty else { return }
        Task {
            let refs = await importImages(urls)
            drafts[key, default: Draft()].images += refs
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
                if self.websiteURL != status.websiteURL { self.websiteURL = status.websiteURL }
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
        return .tb("THREADBEAR_HOME=\(Self.shellQuoted(dataDir.path)) tb")
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

    /// Whether the section remembered for this thread is open in the dock.
    func showsPanels(for thread: ThreadSummary) -> Bool { dock.layout.contains(paneSection(for: thread).id) }

    func activePanel(for thread: ThreadSummary) -> Panel? {
        PanelChoice.active(in: thread.panels, remembered: panelChoice[thread.id])
    }

    /// The thread's pane section: the one last chosen while it's still
    /// there, else Highlights. Previews open over it.
    func paneSection(for thread: ThreadSummary) -> PaneSection {
        PanelChoice.section(panels: thread.panels, hasPatches: !thread.patches.isEmpty, remembered: panelChoice[thread.id])
    }

    /// Shows a section's panel (the automation's `panel`), closing any
    /// preview over another one.
    func choosePanel(_ panelId: String, in threadId: String) {
        if panePreview[threadId]?.from.id != panelId { panePreview[threadId] = nil }
        panelChoice[threadId] = panelId
        showPane(PaneSection(id: panelId))
    }

    /// A rail button, VS Code's way: closes the section's panel if it's
    /// showing, else brings it up (WindowDock).
    func clickRail(_ section: PaneSection, in thread: ThreadSummary) {
        if panePreview[thread.id].map({ $0.from != section }) ?? false { panePreview[thread.id] = nil }
        panelChoice[thread.id] = section.id
        if dock.isShowing(section.id) { dock.close(section.id) } else { showPane(section) }
    }

    func togglePanels() { panelsShown.toggle() }

    /// The sidebar's panel, from the View menu: closed, or opened down the
    /// left of the window.
    func toggleThreadsPanel() {
        if dock.layout.contains(WindowDock.threads) { dock.close(WindowDock.threads) } else { dock.open(WindowDock.threads, .window(.left)) }
    }

    static func actionKey(threadId: String, actionId: String) -> String { "\(threadId)/\(actionId)" }

    func isRunning(action: Action, in threadId: String) -> Bool {
        runningActions.contains(Self.actionKey(threadId: threadId, actionId: action.id))
    }

    /// Runs an action chip: the runner sends a prompt action as a message,
    /// or runs a command action and puts its output in the transcript.
    func runAction(_ action: Action, in threadId: String) {
        let key = Self.actionKey(threadId: threadId, actionId: action.id)
        guard !runningActions.contains(key), let client = client(for: threadId) else { return }
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

    /// Trusts patch files waiting in a thread's folder, as the Patches
    /// panel showed them; the runner then loads them.
    func trustPatches(_ patches: [PatchInfo], in threadId: String) {
        let files = patches.compactMap { p in p.file.flatMap { f in p.hash.map { (file: f, hash: $0) } } }
        guard !files.isEmpty, let client = client(for: threadId) else { return }
        Task {
            do {
                try await client.trustPatches(threadId: threadId, files: files)
            } catch {
                errorMessage = "Couldn't trust \(patches.count == 1 ? patches[0].id : "the patches"): \(error.localizedDescription)"
            }
        }
    }

    /// An image panel's latest picture or a list panel's rows, or nil when
    /// the runner can't be asked (not connected). `failure` is the note
    /// when it couldn't answer.
    func renderPanel(threadId: String, panelId: String, failure: String) async -> PanelRender? {
        guard let client = client(for: threadId) else { return nil }
        do {
            return try await client.renderPanel(threadId: threadId, panelId: panelId)
        } catch {
            AppLog.write("panels", "render \(panelId) failed: \(error)")
            return PanelRender(note: failure)
        }
    }

    /// Available cloud deployments for the panel's project.
    func convexPanelDeployments(threadId: String, panelId: String, refresh: Bool = false) async -> Result<ConvexDeployments, Error> {
        guard let client = client(for: threadId) else { return .failure(RPCError.disconnected(nil)) }
        do {
            return .success(try await client.convexPanelDeployments(threadId: threadId, panelId: panelId, refresh: refresh))
        } catch {
            return .failure(error)
        }
    }

    /// A deploy key for the selected deployment, or the CLI's reason when
    /// it couldn't make one.
    func convexPanelKey(threadId: String, panelId: String, deployment: String? = nil, renew: Bool = false) async -> Result<ConvexPanelKey, Error> {
        guard let client = client(for: threadId) else { return .failure(RPCError.disconnected(nil)) }
        do {
            return .success(try await client.convexPanelKey(threadId: threadId, panelId: panelId, deployment: deployment, renew: renew))
        } catch {
            AppLog.write("panels", "convex key for \(panelId) failed: \(error.localizedDescription)")
            return .failure(error)
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
