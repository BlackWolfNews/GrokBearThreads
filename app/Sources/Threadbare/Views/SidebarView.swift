import AppKit
import SwiftUI
import ThreadbareCore

/// Sizes the sidebar's rows share, so the new-thread row, the headings, the
/// thread titles and the view headers all start at the same x.
enum SidebarMetrics {
    /// From the sidebar's edges to a row's highlight.
    static var outerInset: CGFloat { zoomed(8) }
    /// Inside a row's highlight, left of its text. Wider than the right side
    /// (10) to leave a gutter for the unread dot, as Mail does, so titles
    /// line up whether or not they have one.
    static var leading: CGFloat { zoomed(18) }
    static var trailing: CGFloat { zoomed(10) }
    static var corner: CGFloat { zoomed(8) }
    /// Fainter than the selected row's 0.06 to 0.08, so the two read apart.
    static let hover = Color.primary.opacity(0.03)
    /// Times and counts: quieter than a title but readable
    /// (the system tertiary was about 2:1 here, like disabled text).
    static let faint = Color(nsColor: Theme.faintText)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // VS Code style: a column of icons down the left for the views and
        // the window-wide things, and the chosen view beside it.
        HStack(spacing: 0) {
            // Drawn over the list: its keys hang out to the right while ⌘
            // is held (ShortcutHints).
            ActivityBar()
                .zIndex(1)
            // In a ZStack so the old view and the new one share the space
            // while one fades out and the other fades in and settles.
            ZStack {
                Group {
                    switch app.sidebarMode {
                    case .inbox: InboxList()
                    case .snoozed: SnoozedList()
                    case .archive: ArchiveList()
                    case .scheduled: ScheduledList()
                    case .projects: ProjectsList()
                    case .librarian: LibrarianView()
                    }
                }
                .transition(Juice.reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: zoomed(6))),
                    removal: .opacity
                ))
            }
            .frame(maxWidth: .infinity)
            .animation(Juice.reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: app.sidebarMode)
        }
    }
}

private struct InboxList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sections = app.sections
        // Rows are identified by section and thread (see SectionRow), so
        // the arrow keys scroll to that.
        let rowIDs = Dictionary(uniqueKeysWithValues: InboxSection.allCases.flatMap { section in
            sections[section].map { ($0.id, SectionRow.id(section: section.title, thread: $0.id)) }
        })
        VStack(spacing: 0) {
            SidebarButtonRow(icon: "square.and.pencil", title: "New thread", shortcut: "⌘N", tip: "Start a new thread (⌘N)", active: app.selection == nil) {
                app.newThread()
            }
            .padding(.horizontal, SidebarMetrics.outerInset)
            .padding(.top, zoomed(4))
            // A folded section's rows aren't drawn, so the arrow keys skip them.
            let order = InboxSection.allCases.filter { !app.collapsedSections.contains($0) }.flatMap { sections[$0].map(\.id) }
            // Section and thread, so a thread changing section animates
            // even when the order of ids alone stays the same.
            let layout = InboxSection.allCases.filter { !app.collapsedSections.contains($0) }.flatMap { section in
                sections[section].map { SectionRow.id(section: section.title, thread: $0.id) }
            }
            ThreadList(order: order, layout: layout, scrollID: { rowIDs[$0] ?? $0 }) { select in
                if app.threadsLoaded {
                    ForEach(InboxSection.allCases, id: \.self) { section in
                        ThreadSection(section: section, threads: sections[section], select: select)
                    }
                    if sections.all.isEmpty {
                        InboxZero()
                    }
                }
            }
        }
    }
}

/// A heading and its rows. Empty sections other than Inbox are left out.
/// Clicking the heading folds the rows away; folded, it shows how many.
private struct ThreadSection: View {
    @Environment(AppModel.self) private var app
    let section: InboxSection
    let threads: [ThreadSummary]
    let select: (String) -> Void

    var body: some View {
        if !threads.isEmpty || section == .inbox {
            let collapsed = app.collapsedSections.contains(section)
            SectionHeading(title: section.title, icon: section.icon, fold: .init(collapsed: collapsed, count: threads.count) {
                withAnimation(.snappy(duration: 0.2)) {
                    if collapsed { app.collapsedSections.remove(section) } else { app.collapsedSections.insert(section) }
                }
            })
            if !collapsed {
                ForEach(threads.map { SectionRow(section: section.title, thread: $0) }) { row in
                    ThreadRowView(thread: row.thread, mode: .inbox, section: section) { select(row.thread.id) }
                        .transition(Juice.row)
                    SubagentList(thread: row.thread, section: section.title)
                }
            }
        }
    }
}

/// A row's identity in the lazy stack includes its section. Keyed by the
/// thread id alone, a thread that moved section kept the row it had drawn
/// before (it went to Running still showing its time, not "Working"): the
/// stack moved the row without running its body again. So no plain
/// `.id(thread.id)` on these rows either; the stack keys rows by that too.
struct SectionRow: Identifiable {
    let section: String
    let thread: ThreadSummary
    var id: String { Self.id(section: section, thread: thread.id) }

    static func id(section: String, thread: String) -> String { section + "/" + thread }
}

struct SectionHeading: View {
    let title: String
    /// A small SF Symbol before the title, so the groups can be told apart
    /// at a glance.
    var icon: String? = nil
    /// Given for a heading that folds its rows away when clicked.
    var fold: Fold? = nil
    @State private var hovering = false

    struct Fold {
        var collapsed: Bool
        /// The rows under it, shown while they're folded away.
        var count: Int
        var toggle: () -> Void
    }

    var body: some View {
        if let fold {
            Button(action: fold.toggle) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .tip(fold.collapsed ? "Show \(title)" : "Hide \(title)")
                .accessibilityValue(fold.collapsed ? "Collapsed" : "Expanded")
        } else {
            label
        }
    }

    private var label: some View {
        // A quiet divider rather than a bold tag: grey, at the previews'
        // size, with clear room above each group, like Codex and Claude.
        // Semibold so it isn't weaker than the rows it groups. A hairline
        // runs from the title to the edge so the groups read as separate
        // (Mike asked 27 Oct).
        HStack(spacing: zoomed(6)) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: zoomed(11), weight: .medium))
                    .frame(width: zoomed(14))
            }
            Text(title)
                .font(.system(size: TypeScale.sidebarHeading, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .animation(Juice.hover, value: hovering)
                .fixedSize()
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, zoomed(4))
            if let fold {
                // Folded, the count says what's hidden; the chevron only
                // shows while folded or on hover, so an open heading stays
                // as quiet as the others.
                if fold.collapsed && fold.count > 0 {
                    // Rolls to the new number when a thread comes or goes
                    // while the section's folded.
                    Text("\(fold.count)")
                        .font(.system(size: TypeScale.sidebarMeta))
                        .foregroundStyle(SidebarMetrics.faint)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(fold.count)))
                        .animation(Juice.swap, value: fold.count)
                        .transition(Juice.popIn)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: zoomed(9), weight: .semibold))
                    .foregroundStyle(SidebarMetrics.faint)
                    .rotationEffect(.degrees(fold.collapsed ? -90 : 0))
                    .opacity(fold.collapsed || hovering ? 1 : 0)
                    .animation(Juice.hover, value: hovering)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, SidebarMetrics.leading)
        .padding(.trailing, SidebarMetrics.trailing)
        .padding(.top, zoomed(18))
        .padding(.bottom, zoomed(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension InboxSection {
    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .running: return "bolt"
        }
    }
}

/// The scrolling part of each sidebar view: a lazy stack of rows with
/// up and down arrow keys once it has focus, as the system list had. Rows
/// are drawn here rather than in a `List` because the sidebar list style
/// paints its own accent-coloured selection, which can't be made as quiet
/// as the other agent apps' grey highlight.
struct ThreadList<Content: View>: View {
    @Environment(AppModel.self) private var app
    /// Thread ids top to bottom, for the arrow keys.
    let order: [String]
    /// The rows as drawn, when that says more than `order` (the inbox's
    /// carry their section). A change to it animates the rows into place.
    var layout: [String]? = nil
    /// The id a thread's row has in the stack, to scroll it into view.
    var scrollID: (String) -> String = { $0 }
    @ViewBuilder let content: (_ select: @escaping (String) -> Void) -> Content
    @FocusState private var focused: Bool
    @Namespace private var rowSpace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content { id in
                        // Clicking a row gives the list focus, so the arrow
                        // keys move through threads from there.
                        focused = true
                        app.select(id)
                    }
                }
                .environment(\.sidebarRowSpace, rowSpace)
                // Only when rows come, go or change places, or the selection
                // moves: text changing inside a row (a new title, the
                // clock) isn't animated by these.
                .animation(Juice.rows, value: layout ?? order)
                .animation(Juice.selection, value: SelectionKey(thread: app.selection, subagent: app.subagentSelection, project: app.openProjectId))
                .padding(.horizontal, SidebarMetrics.outerInset)
                // Room for the last row to scroll clear of the fade below.
                .padding(.bottom, zoomed(32))
            }
            // With a mouse connected macOS draws a legacy scroller with a
            // track down the list, which also pushed the times left. Codex,
            // Claude and T3 show none; the list scrolls the same without it.
            .scrollIndicators(.never)
            // The last row fades out at the foot rather than being cut
            // through its text at the hairline, as the transcript does above
            // the composer. About a title and a preview tall, and clear just
            // before the hairline: at 16 pt a row still showed half its
            // letters on the rule. A static mask, so scrolling costs nothing.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: zoomed(30))
                    Color.clear.frame(height: zoomed(4))
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                let step: Int
                switch direction {
                case .up: step = -1
                case .down: step = 1
                default: return
                }
                guard let next = SidebarOrder.neighbour(of: app.selection, in: order, step: step), next != app.selection else { return }
                app.select(next)
                proxy.scrollTo(scrollID(next))
            }
            .onExitCommand {
                if app.sidebarMode != .inbox { app.sidebarMode = .inbox }
            }
        }
    }
}

/// What's selected in the sidebar, for animating the highlight's slide.
private struct SelectionKey: Equatable {
    let thread: String?
    let subagent: SubagentRef?
    let project: String?
}

/// Which list a row is in, for its hover buttons.
extension SidebarMode {
    var rowActions: [RowAction] {
        switch self {
        case .inbox, .projects: return [.snooze, .archive]
        case .snoozed: return [.unsnooze, .archive]
        case .archive: return [.unarchive]
        case .scheduled, .librarian: return []
        }
    }
}

enum RowAction {
    case snooze, archive, unsnooze, unarchive
}

struct ThreadRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    let thread: ThreadSummary
    let mode: SidebarMode
    /// The inbox section the row is under, so it doesn't repeat its heading.
    var section: InboxSection? = nil
    /// The project whose heading the row is under (the Projects view), so
    /// the row doesn't name it again.
    var heading: String? = nil
    let select: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    /// A brief accent wash over a row that's just finished, so a reply
    /// landing in the inbox catches the eye.
    @State private var landed = false
    @Environment(\.sidebarRowSpace) private var listSpace
    /// Not in Projects: a thread in two projects has a row under each, and
    /// two rows can't both be the one the highlight and the glide follow.
    private var rowSpace: Namespace.ID? { mode == .projects ? nil : listSpace }

    /// Not while one of its sub-agents is showing: that row is highlighted.
    private var isSelected: Bool { app.selection == thread.id && app.subagentSelection == nil && app.openProjectId == nil && !app.showsProjectsHome }
    /// The screenshot run shows one row as if the pointer were over it.
    private var showsActions: Bool { hovering || app.hoverOverride == thread.id }

    var body: some View {
        // The Projects view's rows say what they're doing too: it has no
        // Needs you or Running headings to say it for them.
        let look = mode == .inbox || mode == .projects ? ThreadRowLook(thread, section: section) : ThreadRowLook(status: .time, unread: false, emphasised: false)
        // A tile for the thread's project, two lines tall, then the title
        // across the whole width and under it where the thread belongs and
        // what it's doing. The preview and the account name went once
        // projects came: Mike reads a thread by its title and its project.
        HStack(alignment: .center, spacing: zoomed(10)) {
            ProjectTiles(projects: ProjectMark.shown(thread, under: heading))
                .tip(ProjectMark.help(thread))
                .overlay(alignment: .leading) {
                    if look.done {
                        // Finished with nothing needed: a tick where the
                        // unread dot would be, drawn on as it arrives.
                        Image(systemName: "checkmark")
                            .font(.system(size: zoomed(9), weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: zoomed(10), height: zoomed(10))
                            .transition(Juice.reduceMotion ? .opacity : AnyTransition(SymbolEffectTransition(effect: .drawOn, options: .default)))
                            .offset(x: -(SidebarMetrics.leading + zoomed(10)) / 2 - zoomed(1))
                            .accessibilityLabel("Done, unread")
                    } else if look.unread {
                        // In the row's leading gutter, left of the tile. Pops
                        // in with a little overshoot, and shrinks away once
                        // the thread's been read.
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: zoomed(7), height: zoomed(7))
                            .transition(Juice.popIn)
                            .offset(x: -(SidebarMetrics.leading + zoomed(7)) / 2 - zoomed(1))
                            .accessibilityLabel("Unread")
                    }
                }
                .animation(Juice.pop, value: look.unread)
                .animation(Juice.pop, value: look.done)
            VStack(alignment: .leading, spacing: zoomed(3)) {
                HStack(spacing: 0) {
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(.system(size: TypeScale.sidebarTitle, weight: look.emphasised ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if showsActions {
                        // Room for the hover buttons, drawn over the row so
                        // they don't change its height.
                        Color.clear.frame(width: CGFloat(mode.rowActions.count) * zoomed(24), height: 1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                    HStack(alignment: .firstTextBaseline, spacing: zoomed(4)) {
                        if let origin = thread.schedule {
                            // A schedule started it, rather than Mike: the
                            // same clock as the Scheduled view's.
                            Image(systemName: "clock")
                                .font(.system(size: TypeScale.sidebarMeta))
                                .tip(StartedBySchedule.tip(origin, current: app.schedule(origin.id)))
                                .accessibilityLabel("Scheduled")
                        }
                        Text(ProjectMark.place(thread, under: heading))
                            .font(.system(size: TypeScale.sidebarMeta + 1))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    Spacer(minLength: zoomed(6))
                    if !showsActions {
                        // A new status ("Working" to "Needs you") blurs
                        // across rather than snapping.
                        trailing(look)
                            .id(look.status)
                            .transition(Juice.reduceMotion ? .opacity : AnyTransition(BlurReplaceTransition(configuration: .downUp)))
                    }
                }
                .animation(Juice.swap, value: look.status)
            }
        }
        .padding(EdgeInsets(top: zoomed(8), leading: SidebarMetrics.leading, bottom: zoomed(8), trailing: SidebarMetrics.trailing))
        .background {
            if landed {
                RoundedRectangle(cornerRadius: SidebarMetrics.corner)
                    .fill(Color.accentColor.opacity(0.14))
                    .transition(.opacity)
            }
        }
        .rowHighlight(selected: isSelected, hovering: showsActions, selectedColor: selectedColor, space: rowSpace)
        .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        // A slight press while the mouse is down, so a click feels like it
        // landed on something.
        .scaleEffect(pressed && !Juice.reduceMotion ? 0.985 : 1)
        .animation(.snappy(duration: 0.14), value: pressed)
        // The row and its thread's row in another section are one thing,
        // so a move between Running and the Inbox glides.
        .matched("row/" + thread.id, in: rowSpace)
        .onAppear {
            // Only a row turning up within a moment of its turn finishing,
            // unread: a reply that's just arrived, not one scrolled to.
            guard mode == .inbox, look.unread || look.done || look.status == .needsYou,
                  Date().timeIntervalSince(thread.lastActivityAt) < 3 else { return }
            landed = true
            withAnimation(.easeOut(duration: Juice.reduceMotion ? 0.4 : 1.1).delay(0.3)) { landed = false }
        }
        // Selects on mouse down, as the system list did and Mail does; a
        // tap gesture waits for the mouse to come back up.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard !pressed else { return }
            pressed = true
            select()
        }.onEnded { _ in pressed = false })
        // After the gesture, so clicking these never selects the row.
        .overlay(alignment: .trailing) {
            if showsActions {
                RowActions(thread: thread, actions: mode.rowActions)
                    .padding(.trailing, SidebarMetrics.trailing - zoomed(5))
            }
        }
        .onHover { hovering = $0 }
        .animation(Juice.hover, value: showsActions)
        // The whole title, which the row often cuts short, and where it runs.
        // The status and project marks have their own tips over this one.
        .tip((thread.title.isEmpty ? "Untitled" : thread.title) + "\n" + thread.cwd.abbreviatingHome)
        .contextMenu { ThreadMenu(thread: thread) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    private var selectedColor: Color { Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }

    /// A hibernating thread says when it wakes, where the time would be.
    private var wakeText: String? {
        if thread.snoozedUntilRestart { return "Back on restart" }
        if let until = thread.snoozedUntil { return "Back \(RelativeTime.until(until, now: app.now))" }
        return nil
    }

    @ViewBuilder
    private func trailing(_ look: ThreadRowLook) -> some View {
        switch look.status {
        case .time:
            if mode == .snoozed {
                if let wakeText {
                    Text(wakeText).font(.system(size: TypeScale.sidebarMeta)).foregroundStyle(SidebarMetrics.faint)
                }
            } else {
                time.foregroundStyle(SidebarMetrics.faint)
            }
        case .working:
            HStack(alignment: .firstTextBaseline, spacing: zoomed(5)) {
                // An accent arc turned in the render server (SpinnerView):
                // the system mini spinner drew grey whatever the tint, and
                // the symbol's variable colour left it a pale asterisk.
                SpinnerMark(color: .controlAccentColor)
                    .frame(width: zoomed(12), height: zoomed(12))
                    // On the text's baseline, centred on its lowercase.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + zoomed(4) }
                // How long the turn has run, ticking once a second. Only
                // running rows have this, and there are one to three.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = ThreadRowLook.workingLabel(since: thread.lastActivityAt, now: context.date)
                    // The seconds roll over like a counter.
                    Text(look.labelled ? "Working " + elapsed : elapsed).monospacedDigit()
                        .contentTransition(.numericText(countsDown: false))
                        .animation(Juice.swap, value: elapsed)
                }
            }
            .font(.system(size: TypeScale.sidebarMeta, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .tip("Working")
        case .background:
            // Still being worked on, but by sub-agents or jobs in the
            // background: the same spinner in grey, and what's running
            // instead of a clock. Visibly not a streaming turn.
            HStack(alignment: .firstTextBaseline, spacing: zoomed(5)) {
                SpinnerMark(color: .secondaryLabelColor)
                    .frame(width: zoomed(12), height: zoomed(12))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + zoomed(4) }
                Text(BackgroundWork.short(thread.background))
            }
            .font(.system(size: TypeScale.sidebarMeta, weight: .medium))
            .foregroundStyle(.secondary)
            .tip(BackgroundWork.detail(thread.background))
        case .needsYou:
            Text("Needs you").font(.system(size: TypeScale.sidebarMeta, weight: .medium)).foregroundStyle(Color(nsColor: Theme.needsYou))
        case .failed:
            Text("Failed").font(.system(size: TypeScale.sidebarMeta, weight: .medium)).foregroundStyle(Color(nsColor: Theme.failed))
                .tip("The last turn failed")
        case .stopped:
            Text("Stopped").font(.system(size: TypeScale.sidebarMeta)).foregroundStyle(.secondary)
                .tip("Stopped when the runner restarted")
        }
    }

    /// When the thread was last active (archived, in the archive).
    private var time: Text {
        Text(RelativeTime.short(mode == .archive ? thread.archivedAt ?? thread.lastActivityAt : thread.lastActivityAt, now: app.now))
            .font(.system(size: TypeScale.sidebarMeta))
            .monospacedDigit()
    }
}

/// A row's project as a tile two lines tall: the first project it joined,
/// with an edge of a second tile showing behind it when it's in more than
/// one. A quiet folder when it's in none. The front tile is the project's
/// icon: its picture filling the tile, or its symbol or first letter on it.
private struct ProjectTiles: View {
    @Environment(AppModel.self) private var app
    let projects: [ThreadProject]

    var body: some View {
        let size = zoomed(30)
        ZStack(alignment: .bottomLeading) {
            if projects.count > 1 {
                // Up and to the right, so the front tile keeps its place,
                // with the front tile's shape (and a hairline round it) cut
                // out: both are see-through, so the overlap would otherwise
                // show darker, and the selected row's highlight shows
                // through either way.
                RoundedRectangle(cornerRadius: zoomed(7))
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
                    .mask {
                        ZStack {
                            Rectangle()
                            RoundedRectangle(cornerRadius: zoomed(8))
                                .frame(width: size + zoomed(2), height: size + zoomed(2))
                                .offset(x: -zoomed(4), y: zoomed(4))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .offset(x: zoomed(4), y: -zoomed(4))
            }
            let icon = projects.first.flatMap { app.project($0.id)?.icon }
            if let path = icon?.image?.path, let image = ProjectIconImages.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: zoomed(7), style: .continuous))
            } else {
                Group {
                    if let symbol = icon?.symbol, ProjectIconImages.symbolExists(symbol) {
                        Image(systemName: symbol)
                            .font(.system(size: zoomed(14)))
                            .foregroundStyle(.secondary)
                    } else if let project = projects.first {
                        Text(ProjectMark.letter(project.title))
                            .font(.system(size: zoomed(14), weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: zoomed(12)))
                            .foregroundStyle(SidebarMetrics.faint)
                    }
                }
                .frame(width: size, height: size)
                .background(Color.primary.opacity(projects.isEmpty ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: zoomed(7)))
            }
        }
        .frame(width: size + zoomed(4), height: size + zoomed(4), alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}

/// The small buttons a row shows on hover in place of its time.
private struct RowActions: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let actions: [RowAction]

    var body: some View {
        HStack(spacing: zoomed(2)) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                switch action {
                case .snooze:
                    Menu {
                        SnoozeMenuItems(threadId: thread.id, confirmIfBusy: true)
                    } label: {
                        Image(systemName: "moon.zzz")
                    }
                    .menuStyle(.button)
                    .buttonStyle(RowIconButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .tip("Hibernate")
                case .archive:
                    Button {
                        guard BusyConfirm.allowed(.archive, threadId: thread.id, app: app) else { return }
                        app.archive(thread.id)
                    } label: { Image(systemName: "archivebox") }
                        .buttonStyle(RowIconButtonStyle())
                        .tip("Archive (⌘E)")
                case .unsnooze:
                    Button { app.unsnooze(thread.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(RowIconButtonStyle())
                        .tip("Wake")
                case .unarchive:
                    Button { app.unarchive(thread.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(RowIconButtonStyle())
                        .tip("Unarchive")
                }
            }
        }
    }
}

/// A 22 pt (at 100%) borderless icon button with its own faint hover square.
struct RowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowIconButton(configuration: configuration)
    }

    private struct RowIconButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: zoomed(13)))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: zoomed(22), height: zoomed(22))
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: zoomed(5))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A full-width sidebar row that does one thing: New thread at the top of
/// the inbox, New schedule at the top of Scheduled.
struct SidebarButtonRow: View {
    let icon: String
    let title: String
    /// Shown at the row's end while ⌘ is held (`ShortcutHints`). It used
    /// to be printed there all the time, which Mike found noisy.
    var shortcut: String? = nil
    /// The tooltip, if the title alone doesn't say enough.
    var tip: String? = nil
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            HStack(spacing: zoomed(8)) {
                Image(systemName: icon)
                    .font(.system(size: TypeScale.sidebarButton))
                    .foregroundStyle(.secondary)
                    .frame(width: zoomed(16))
                Text(title)
                    .font(.system(size: TypeScale.sidebarButton))
                    .foregroundStyle(.primary)
                Spacer(minLength: zoomed(6))
            }
            // The icon sits where thread titles start, Codex style.
            .padding(.leading, SidebarMetrics.leading - zoomed(2))
            .padding(.trailing, SidebarMetrics.trailing)
            .padding(.vertical, zoomed(7))
            .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
            .shortcutHint(shortcut, .insideTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(tip ?? shortcut.map { "\(title) (\($0))" } ?? title)
    }

    private var background: Color {
        if active { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return hovering ? SidebarMetrics.hover : .clear
    }
}

/// Snooze, archive and copy, shared by the context menu and the toolbar.
struct ThreadMenu: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        SnoozeMenu(threadId: thread.id)
        if thread.snoozedUntil != nil {
            Button("Wake") { app.unsnooze(thread.id) }
        }
        if thread.isArchived {
            Button("Unarchive") { app.unarchive(thread.id) }
        } else {
            Button("Archive") { app.archive(thread.id) }
        }
        if app.projectsSupported {
            ThreadProjectsMenu(thread: thread)
        }
    }
}

/// "Projects ▸": a tick by each project the thread is in (choosing one
/// puts it in or takes it out, by hand, so it's pinned or remembered), a
/// new one, and asking the librarian to look at it now.
struct ThreadProjectsMenu: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        Menu("Projects") {
            let live = app.projects.filter { !$0.archived }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            ForEach(live) { project in
                let inIt = thread.projects.contains { $0.id == project.id }
                Toggle(project.title, isOn: Binding(
                    get: { inIt },
                    set: { on in app.setProjects(thread.id, add: on ? [project.id] : [], remove: on ? [] : [project.id]) }
                ))
            }
            if !live.isEmpty { Divider() }
            Button("New project…") { app.newProject(with: thread.id) }
            Button("Ask the librarian to look") { app.runLibrarian(threadId: thread.id) }
        }
    }
}

struct SnoozeMenu: View {
    let threadId: String

    var body: some View {
        Menu("Hibernate") { SnoozeMenuItems(threadId: threadId) }
    }
}

/// The snooze presets and "Pick a time…". Titles follow `app.now`; the date
/// is worked out when an item is chosen, not when the menu was built.
struct SnoozeMenuItems: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    /// From a row's hover button: ask before snoozing a thread whose turn
    /// is underway, which stops the turn.
    var confirmIfBusy = false

    var body: some View {
        ForEach(Snooze.presets(now: app.now)) { preset in
            Button(preset.title) {
                guard allowed() else { return }
                app.snooze(threadId, until: Snooze.date(for: preset.id, now: Date()))
            }
        }
        if app.restartPending {
            Button(Snooze.untilRestartTitle) {
                guard allowed() else { return }
                app.snoozeUntilRestart(threadId)
            }
        }
        Divider()
        Button("Pick a time…") {
            guard allowed() else { return }
            SnoozePicker.show(threadId: threadId, app: app)
        }
    }

    private func allowed() -> Bool {
        !confirmIfBusy || BusyConfirm.allowed(.snooze, threadId: threadId, app: app)
    }
}

/// Asks before a hover button stops a running turn (`BusyThreadAction`).
@MainActor
enum BusyConfirm {
    /// Whether to go ahead: the thread isn't busy, or Mike said yes. Its
    /// status is read now, not when the row was drawn.
    static func allowed(_ action: BusyThreadAction.Action, threadId: String, app: AppModel) -> Bool {
        guard let thread = app.threads[threadId], BusyThreadAction.needsConfirm(thread) else { return true }
        let prompt = BusyThreadAction.prompt(action, thread: thread)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        alert.addButton(withTitle: action == .archive ? "Archive" : "Hibernate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct SnoozedList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let snoozed = app.snoozed
        VStack(spacing: 0) {
            ModeHeader(title: "Hibernating", count: snoozed.count)
            ThreadList(order: snoozed.map(\.id)) { select in
                ForEach(snoozed) { thread in
                    ThreadRowView(thread: thread, mode: .snoozed) { select(thread.id) }
                        .id(thread.id)
                        .transition(Juice.row)
                }
                if snoozed.isEmpty {
                    EmptyNote(text: "Nothing hibernating.")
                }
            }
        }
    }
}

private struct ArchiveList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let archived = app.archived
        VStack(spacing: 0) {
            ModeHeader(title: "Archive", count: app.archiveLoaded ? app.archivedCount : nil)
            // The way settled threads are found again, so it stays here
            // although the inbox has no search.
            SearchField(text: $app.archiveQuery, prompt: "Search the archive")
                .padding(.horizontal, SidebarMetrics.outerInset)
                .padding(.top, zoomed(4))
                .padding(.bottom, zoomed(6))
            ThreadList(order: archived.map(\.id)) { select in
                ForEach(archived) { thread in
                    ThreadRowView(thread: thread, mode: .archive) { select(thread.id) }
                        .id(thread.id)
                        .transition(Juice.row)
                }
                if archived.isEmpty {
                    EmptyNote(text: app.archiveLoaded ? "Nothing archived matches." : "Loading…")
                }
            }
        }
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.sidebarPreview))
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.leading)
            .padding(.top, zoomed(10))
    }
}

/// The top of the Hibernating, Archive and Scheduled views: the view's name
/// and its count. The activity bar's top icon (or Esc) goes back to the
/// inbox, so there's no back button.
struct ModeHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: zoomed(6)) {
            Text(title)
                .font(.system(size: TypeScale.sidebarButton, weight: .semibold))
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.system(size: TypeScale.sidebarFooter)).foregroundStyle(SidebarMetrics.faint).monospacedDigit()
            }
        }
        // On the same column as the titles below.
        .padding(.leading, SidebarMetrics.outerInset + SidebarMetrics.leading)
        .padding(.trailing, SidebarMetrics.outerInset + SidebarMetrics.trailing)
        .padding(.top, zoomed(4))
        .frame(height: zoomed(34))
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        // The glass and the prompt on the same columns as New thread's icon
        // and title, as SidebarButtonRow lays them out.
        HStack(spacing: zoomed(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: zoomed(12.5)))
                .foregroundStyle(SidebarMetrics.faint)
                .frame(width: zoomed(16))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.sidebarButton))
                .tip(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .tip("Clear")
            }
        }
        .padding(.leading, SidebarMetrics.leading - zoomed(2))
        .padding(.trailing, zoomed(9))
        .padding(.vertical, zoomed(6))
        // A field, not a row: a lighter fill and a hairline. At the selected
        // row's fill it read as a selected item stacked on the list.
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        .overlay(RoundedRectangle(cornerRadius: SidebarMetrics.corner).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// "Pick a time" for snoozing: a small sheet with a date picker.
@MainActor
enum SnoozePicker {
    static func show(threadId: String, app: AppModel) {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = Date().addingTimeInterval(3 * 3600)
        picker.minDate = Date()
        picker.sizeToFit()
        let alert = NSAlert()
        alert.messageText = "Hibernate until"
        alert.accessoryView = picker
        alert.addButton(withTitle: "Hibernate")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            app.snooze(threadId, until: picker.dateValue)
        }
    }
}
