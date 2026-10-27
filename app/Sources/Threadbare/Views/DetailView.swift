import AppKit
import SwiftUI
import ThreadbareCore

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    static var sidebarIdealWidth: CGFloat { zoomed(360) }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            // About a quarter of the window, as T3, Codex and Claude give
            // theirs: at 290 most titles were cut at about 25 characters.
            // At the default 1180 pt window the detail pane still fits the
            // 780 pt reading column and its insets. 30 wider since the
            // activity bar (44) took the left of it.
            SidebarView()
                .navigationSplitViewColumnWidth(min: zoomed(290), ideal: Self.sidebarIdealWidth, max: zoomed(480))
        } detail: {
            DetailView()
        }
        .sheet(item: $app.scheduleEditor) { state in
            ScheduleEditor(state: state)
        }
        // The automation's `settings` opens the Settings window; only a
        // SwiftUI view can (AppKit's showSettingsWindow: does nothing now).
        .onChange(of: app.settingsRequest) { openSettings() }
        // Saves where the window is, so the next launch opens it there.
        .background(MainWindowFrameTracker())
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var app
    /// The pane's width in 20 pt steps, to cap the header's width so a long
    /// title truncates instead of going into the toolbar's overflow menu.
    /// Stepped so a live resize re-renders this view a few times, not on
    /// every frame.
    @State private var widthStep: CGFloat = 900

    var body: some View {
        let thread = app.selectedThread
        // A sub-agent's transcript, read-only, in place of its thread's.
        let subagentRef = app.subagentSelection
        let session = subagentRef.map { app.subagentSession(for: $0) } ?? app.selection.map { app.session(for: $0) }
        let isNew = app.selection == nil
        let paneThread = thread.flatMap { app.showsPanels(for: $0) ? $0 : nil }
        // A project's page takes the place of the thread (and its panels)
        // until a thread is picked again.
        let project = app.openProject
        Group {
        if let project {
            VStack(spacing: 0) {
                ConnectionBanner()
                ErrorBanner()
                ProjectPage(project: project)
            }
        } else {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
            ConnectionBanner()
            ErrorBanner()
            if let thread { LimitBanner(thread: thread) }
            if let thread, thread.hasPendingReviews, subagentRef == nil {
                PendingReviewsButton(thread: thread)
            }
            if let subagentRef {
                SubagentHeader(ref: subagentRef)
            }
            ComposerPlacement(centred: isNew) {
                ZStack {
                    TranscriptView(session: session, controller: app.transcript)
                    if let session, session.state == .loading, session.displayCount == 0 {
                        ProgressView().controlSize(.small)
                    } else if let session, session.missing {
                        Text("There's no record of what this sub-agent did.")
                            .foregroundStyle(.secondary)
                    } else if let session, session.subagentId != nil, session.state == .loaded, session.displayCount == 0 {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    } else if let session, session.subagentId != nil, case .failed(let message) = session.state {
                        VStack(spacing: zoomed(8)) {
                            Text("Couldn't load this sub-agent.").font(.headline)
                            Text(message).foregroundStyle(.secondary)
                            Button("Try again") { app.selectSubagent(threadId: session.threadId, subagentId: session.subagentId ?? "") }
                        }
                    } else if let session, case .failed(let message) = session.state {
                        VStack(spacing: zoomed(8)) {
                            Text("Couldn't load this thread.").font(.headline)
                            Text(message).foregroundStyle(.secondary)
                            Button("Try again") { app.select(session.threadId) }
                        }
                    }
                }
                .layoutValue(key: PaneRole.self, value: .transcript)
                // A sub-agent can't be written to: it takes its brief from
                // the agent that started it.
                if subagentRef == nil {
                    ComposerView(thread: thread)
                        .layoutValue(key: PaneRole.self, value: .composer)
                }
                if isNew {
                    NewThreadHeading()
                        .layoutValue(key: PaneRole.self, value: .heading)
                    NewThreadNote()
                        .layoutValue(key: PaneRole.self, value: .note)
                }
            }
            }
            .frame(maxWidth: .infinity)
            // The panels pane (PanelsView), when the thread's folder has
            // any and Mike hasn't hidden it.
            if let paneThread {
                PanelResizeHandle(columnWidth: widthStep)
                PanelPane(thread: paneThread)
                    .frame(width: CGFloat(PanelChoice.clampedWidth(Double(app.panelWidth), paneColumnWidth: Double(widthStep))))
            }
        }
        }
        }
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded(.down) * 20 } action: { widthStep = $0 }
        // The window's title (Window menu, Mission Control); the toolbar
        // shows the header below instead.
        .navigationTitle(project?.title ?? thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "New thread")
        .toolbar(removing: .title)
        .toolbar {
            // Both items are always there, the header empty and the menu
            // disabled with no thread selected: building toolbar items on
            // the first selection cost about 40 ms of that first open
            // (NSToolbarView layout), on top of the transcript.
            ToolbarItem(placement: .navigation) {
                Group {
                    if let project {
                        ProjectHeaderTitle(project: project)
                    } else {
                        HeaderTitle(thread: thread)
                    }
                }
                .frame(maxWidth: max(120, widthStep - 120), alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            // With the system title gone nothing pushes the menu to the
            // trailing edge; it sat right after the header.
            ToolbarSpacer(.flexible)
            // Shows or hides the panels pane. Always built, like the menu
            // beside it, and out of sight for a thread with no panels.
            ToolbarItem(placement: .primaryAction) {
                let hasPanels = project == nil && (thread.map { !$0.panels.isEmpty || !$0.patches.isEmpty } ?? false)
                Button {
                    app.togglePanels()
                } label: {
                    Label(app.panelsShown ? "Hide Panels" : "Show Panels", systemImage: "sidebar.trailing")
                }
                .help(app.panelsShown ? "Hide the panels" : "Show the panels")
                .disabled(!hasPanels)
                .opacity(hasPanels ? 1 : 0)
                .allowsHitTesting(hasPanels)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                let hasMenu = thread != nil || project != nil
                Menu {
                    if let project {
                        ProjectMenu(project: project)
                    } else if let thread {
                        ThreadMenu(thread: thread)
                        Divider()
                        Button("Copy transcript as Markdown") { session?.copyTranscript() }
                        // So Mike can point an agent at this thread (`tb show <id>`).
                        Button("Copy thread id") { app.copyToPasteboard(thread.id) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More")
                .disabled(!hasMenu)
                // Still built (see above), but out of sight with nothing to
                // act on: a dimmed "..." alone in an empty new thread's
                // header looked broken.
                .opacity(hasMenu ? 1 : 0)
                .allowsHitTesting(hasMenu)
            }
            // A plain glyph like Codex's and Claude's. Its glass disc drew
            // dark grey on a light window.
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// One line, T3 style: the folder's name, then the title, and "Archived"
/// for an archived thread, then its projects as chips. The full path is in
/// the tooltip.
private struct HeaderTitle: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary?

    var body: some View {
        if let thread {
            HStack(spacing: zoomed(5)) {
                Text(FolderName.short(thread.cwd))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text("/")
                    .foregroundStyle(Color(nsColor: Theme.faintText))
                    .layoutPriority(1)
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if thread.isArchived {
                    // A quiet word here rather than a full-width band under
                    // the header, which nothing else in the window had.
                    // Unarchive is in the ... menu, ⌘E and the row's hover
                    // button.
                    Text("·  Archived").foregroundStyle(Color(nsColor: Theme.faintText)).layoutPriority(1)
                }
                if thread.onOldRunner {
                    // A handover (protocol "Handovers"): this turn began
                    // before the runner updated, so a fix just merged isn't
                    // in it yet. The flag goes when the turn ends.
                    Text("·  Finishing on the previous version")
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                        .layoutPriority(1)
                        .help("This turn started before the runner updated, so it runs on the previous version. The thread moves to the new one when the turn ends.")
                }
                if let worktree = thread.worktree {
                    // Its own worktree (protocol "Worktrees"): the branch,
                    // quietly, as the folder above is the worktree's.
                    Text("·  \(worktree.branch)")
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                        .layoutPriority(1)
                        .help("Works on its own branch in a worktree. tb land, or the Land chip, puts it on main in \(worktree.mainCheckout.abbreviatingHome).")
                }
                if app.projectsSupported, !thread.projects.isEmpty {
                    ProjectChips(thread: thread)
                        .padding(.leading, zoomed(4))
                        .layoutPriority(1)
                }
            }
            .font(.system(size: TypeScale.header))
            .lineLimit(1)
            .padding(.leading, zoomed(6))
            .help(thread.cwd.abbreviatingHome)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// "Projects / Threadbear" while a project's page is open.
private struct ProjectHeaderTitle: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        HStack(spacing: zoomed(5)) {
            Button("Projects") { app.showProjects() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show the Projects view")
                .layoutPriority(1)
            Text("/")
                .foregroundStyle(Color(nsColor: Theme.faintText))
                .layoutPriority(1)
            Text(project.title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            if project.archived {
                Text("·  Archived").foregroundStyle(Color(nsColor: Theme.faintText)).layoutPriority(1)
            }
        }
        .font(.system(size: TypeScale.header))
        .lineLimit(1)
        .padding(.leading, zoomed(6))
    }
}

/// The thread's projects, small and grey after its title. A click opens the
/// project's page; the context menu takes the thread out, keeps it there
/// (for one the librarian put it in), or adds it to another. A dashed edge
/// is the librarian's guess that no one has confirmed yet.
private struct ProjectChips: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: zoomed(4)) {
            ForEach(thread.projects) { membership in
                ProjectChip(thread: thread, membership: membership)
            }
        }
    }
}

private struct ProjectChip: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let membership: ThreadProject
    @State private var hovering = false

    private var guessed: Bool { membership.by == .librarian && !membership.pinned }
    private var title: String { app.project(membership.id)?.title ?? membership.title }

    var body: some View {
        Button { app.openProjectPage(membership.id) } label: {
            Text(title)
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, zoomed(7))
                .padding(.vertical, zoomed(2))
                .background(Color.primary.opacity(hovering ? 0.08 : 0.05), in: Capsule())
                .overlay {
                    if guessed {
                        Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 2]))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(guessed ? "The librarian put this thread in \(title). Right-click to keep it there or take it out." : "Open \(title)")
        .contextMenu {
            Button("Open \(title)") { app.openProjectPage(membership.id) }
            Divider()
            if !membership.pinned {
                Button("Keep it in \(title)") { app.setProjects(thread.id, add: [membership.id]) }
            }
            Button("Take it out of \(title)") { app.setProjects(thread.id, remove: [membership.id]) }
            let others = app.projectsToAdd(thread)
            if !others.isEmpty {
                Menu("Add to another project") {
                    ForEach(others) { project in
                        Button(project.title) { app.setProjects(thread.id, add: [project.id]) }
                    }
                }
            }
        }
    }
}

private enum PaneRole: LayoutValueKey {
    static let defaultValue = Role.transcript

    enum Role {
        case transcript, composer, heading, note
    }
}

/// Lays out the pane under the banners: the transcript, then the composer
/// at the bottom. For a new thread the composer sits about 40% of the way
/// down instead, with a heading above it and where the thread will start
/// below it, as Codex and Claude do.
///
/// One layout for both, rather than two views, so the composer is the same
/// view (and keeps its text view and its focus) when the first message
/// creates the thread and it drops to the bottom. The transcript's frame is
/// the same either way, so showing that first thread doesn't resize it.
private struct ComposerPlacement: Layout {
    var centred: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func find(_ role: PaneRole.Role) -> LayoutSubview? { subviews.first { $0[PaneRole.self] == role } }
        let width = ProposedViewSize(width: bounds.width, height: nil)
        // The whole pane either way: the transcript's scroller is an
        // overlay, so its reading column is centred in the pane too.
        let composerWidth = bounds.width
        let composerHeight = find(.composer)?.sizeThatFits(ProposedViewSize(width: composerWidth, height: nil)).height ?? 0
        let transcriptHeight = max(0, bounds.height - composerHeight)
        find(.transcript)?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: transcriptHeight))

        let heading = centred ? find(.heading) : nil
        let note = centred ? find(.note) : nil
        let composerY = bounds.minY + ComposerPlacementMath.composerTop(
            paneHeight: bounds.height, composerHeight: composerHeight, centred: centred,
            headingHeight: Double(heading?.sizeThatFits(width).height ?? 0), noteHeight: Double(note?.sizeThatFits(width).height ?? 0)
        )
        heading?.place(at: CGPoint(x: bounds.minX, y: composerY - zoomed(18)), anchor: .bottomLeading, proposal: width)
        note?.place(at: CGPoint(x: bounds.minX, y: composerY + composerHeight - zoomed(2)), proposal: width)
        // Centred in its width: the composer caps its own width.
        find(.composer)?.place(
            at: CGPoint(x: bounds.minX + composerWidth / 2, y: composerY), anchor: .top,
            proposal: ProposedViewSize(width: composerWidth, height: composerHeight)
        )
    }
}

private struct NewThreadHeading: View {
    var body: some View {
        Text("What should we work on?")
            .font(.system(size: zoomed(24), weight: .semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, zoomed(24))
            .frame(maxWidth: .infinity)
    }
}

/// "Starts in misc on cannstudios": the folder and account the composer's
/// menus are set to. Then every account as a card with the room it has
/// left, so which login to start on is decided looking at the numbers
/// rather than from the usage popover; a click picks it, like the
/// composer's account menu.
private struct NewThreadNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let cwd = app.newThreadCwd ?? app.defaults.cwd
        let account = app.newThreadAccountId
        VStack(spacing: zoomed(14)) {
            Text("Starts in \(FolderName.short(cwd)) on \(app.accountShortTitle(account))")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(Color(nsColor: Theme.faintText))
                .help("\(cwd.abbreviatingHome) on \(app.accountTitle(account))")
            // Only once there's something to compare: an older runner sends
            // no usage, and one account has nothing to choose between.
            let accounts = UsageSections.build(app.accounts).flatMap(\.accounts)
            if accounts.count > 1, accounts.contains(where: { $0.usage != nil }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: zoomed(140), maximum: zoomed(200)), spacing: zoomed(8), alignment: .top)], spacing: zoomed(8)) {
                    ForEach(accounts) { item in
                        AccountRoomCard(account: item, accounts: app.accounts, selected: item.id == account, now: app.now) {
                            app.newThreadAccount = item.id
                        }
                    }
                }
                .frame(maxWidth: Theme.maxContentWidth)
                .padding(.horizontal, zoomed(24))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One account on the new-thread page: its name (the domain when two
/// share the part before the @), a bar of the
/// tighter window, and "5h 89% · week 78% left".
private struct AccountRoomCard: View {
    let account: Account
    let accounts: [Account]
    let selected: Bool
    let now: Date
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        let usage = account.usage
        let tight = AccountUsageText.tightest(usage)
        Button(action: pick) {
            VStack(alignment: .leading, spacing: zoomed(5)) {
                // The note ("Convex work only") beside the name rather than
                // under it, so every card is the same height.
                HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                    Text(AccountName.label(account.id, accounts: accounts))
                        .font(.system(size: zoomed(12), weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let note = account.note, !note.isEmpty {
                        Text(note).font(.system(size: zoomed(11))).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    GeometryReader { geometry in
                        Capsule().fill(fill(usage, tight))
                            .frame(width: max(0, geometry.size.width * (tight?.remainingPercent ?? 0) / 100))
                    }
                }
                .frame(height: zoomed(3))
                Text(AccountUsageText.roomLine(usage) ?? "Nothing known yet")
                    .font(.system(size: zoomed(11)))
                    .monospacedDigit()
                    .foregroundStyle(usage?.blocked == true ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, zoomed(10))
            .padding(.vertical, zoomed(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.07 : hovering ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: zoomed(8)))
            .overlay {
                RoundedRectangle(cornerRadius: zoomed(8))
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: zoomed(8)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(AccountUsageText.tooltip(account, fallback: AccountName.title(account), now: now))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The same colours as the usage popover: grey with room, orange under
    /// a quarter, red at the limit.
    private func fill(_ usage: AccountUsage?, _ tight: UsageWindow?) -> Color {
        guard let tight else { return .clear }
        if usage?.blocked == true || tight.remainingPercent < 1 { return .red }
        if tight.remainingPercent < AccountUsageText.chipWarning { return .orange }
        return Color.primary.opacity(0.4)
    }
}

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let banner = app.banner {
            switch banner.style {
            case .quiet: quiet(banner)
            case .warning: warning(banner)
            }
        }
    }

    /// A runner restart: grey words on the window's own background with a
    /// hairline under them, so it reads as information, not a problem.
    private func quiet(_ banner: Banner) -> some View {
        HStack(spacing: zoomed(8)) {
            if let icon = banner.icon {
                Image(systemName: icon).foregroundStyle(.secondary)
            } else {
                SpinnerMark(color: .secondaryLabelColor).frame(width: zoomed(13), height: zoomed(13))
            }
            Text(banner.text).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let key = banner.dismissKey {
                Button("Dismiss") { app.dismissCliFailure(key) }
                    .buttonStyle(.borderless)
            }
        }
        .font(.system(size: TypeScale.label))
        .help(banner.detail ?? "")
        .padding(.horizontal, zoomed(14))
        .padding(.vertical, zoomed(7))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }

    private func warning(_ banner: Banner) -> some View {
        HStack(spacing: zoomed(8)) {
            Image(systemName: banner.icon ?? "bolt.horizontal").foregroundStyle(.secondary)
            Text(banner.text).lineLimit(2).help(banner.detail ?? "")
            Spacer()
            if banner.showStart {
                Button("Start runner") { app.startRunner() }
            }
            if banner.showRetry {
                Button("Try again") { app.reconnectNow() }
            }
        }
        .padding(.horizontal, zoomed(14))
        .padding(.vertical, zoomed(8))
        .background(.yellow.opacity(0.12))
    }
}

/// The open thread's account is at its limit (or its last turn failed on
/// it): says so, with a button to move the thread to the account with the
/// most room. Here rather than in the transcript's error row, whose drawing
/// is cached and knows nothing of accounts, so the name and the room it
/// offers stay current as usage changes.
private struct LimitBanner: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        if let advice = app.limitAdvice(for: thread) {
            HStack(spacing: zoomed(8)) {
                Image(systemName: "gauge.with.dots.needle.100percent").foregroundStyle(.red)
                Text(advice.text).lineLimit(1)
                Spacer(minLength: zoomed(6))
                if let target = advice.target {
                    Button(AccountUsageText.switchTitle(target, accounts: app.accounts)) {
                        app.switchAccount(thread.id, to: target.id)
                    }
                }
            }
            .font(.system(size: TypeScale.label))
            .padding(.horizontal, zoomed(14))
            .padding(.vertical, zoomed(7))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
        }
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let message = app.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).lineLimit(2)
                Spacer()
                Button("Dismiss") { app.errorMessage = nil }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, zoomed(14))
            .padding(.vertical, zoomed(7))
            .background(.orange.opacity(0.1))
        }
    }
}
