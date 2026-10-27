import AppKit
import SwiftUI
import ThreadbareCore

/// Sizes the sidebar's rows share, so the new-thread row, the headings, the
/// thread titles and the footer all start at the same x.
enum SidebarMetrics {
    /// From the sidebar's edges to a row's highlight.
    static let outerInset: CGFloat = 8
    /// Inside a row's highlight, left of its text. Wider than the right side
    /// (10) to leave a gutter for the unread dot, as Mail does, so titles
    /// line up whether or not they have one.
    static let leading: CGFloat = 18
    static let trailing: CGFloat = 10
    static let corner: CGFloat = 8
    /// Fainter than the selected row's 0.06 to 0.08, so the two read apart.
    static let hover = Color.primary.opacity(0.03)
    /// Times, counts and account names: quieter than a preview but readable
    /// (the system tertiary was about 2:1 here, like disabled text).
    static let faint = Color(nsColor: Theme.faintText)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.sidebarMode {
        case .inbox: InboxList()
        case .snoozed: SnoozedList()
        case .archive: ArchiveList()
        case .scheduled: ScheduledList()
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
            SidebarButtonRow(icon: "square.and.pencil", title: "New thread", hint: "⌘N", active: app.selection == nil) {
                app.newThread()
            }
            .help("New thread (⌘N)")
            .padding(.horizontal, SidebarMetrics.outerInset)
            .padding(.top, 4)
            ThreadList(order: sections.all.map(\.id), scrollID: { rowIDs[$0] ?? $0 }) { select in
                if app.threadsLoaded {
                    ForEach(InboxSection.allCases, id: \.self) { section in
                        ThreadSection(section: section, threads: sections[section], select: select)
                    }
                    if sections.all.isEmpty {
                        EmptyNote(text: "Nothing in the inbox.")
                    }
                }
            }
            SidebarFooter()
        }
    }
}

/// A heading and its rows. Empty sections other than Inbox are left out.
private struct ThreadSection: View {
    let section: InboxSection
    let threads: [ThreadSummary]
    let select: (String) -> Void

    var body: some View {
        if !threads.isEmpty || section == .inbox {
            SectionHeading(title: section.title)
            ForEach(threads.map { SectionRow(section: section.title, thread: $0) }) { row in
                ThreadRowView(thread: row.thread, mode: .inbox, section: section) { select(row.thread.id) }
            }
        }
    }
}

/// A row's identity in the lazy stack includes its section. Keyed by the
/// thread id alone, a thread that moved section kept the row it had drawn
/// before (it went to Running still showing its time, not "Working"): the
/// stack moved the row without running its body again. So no plain
/// `.id(thread.id)` on these rows either; the stack keys rows by that too.
private struct SectionRow: Identifiable {
    let section: String
    let thread: ThreadSummary
    var id: String { Self.id(section: section, thread: thread.id) }

    static func id(section: String, thread: String) -> String { section + "/" + thread }
}

private struct SectionHeading: View {
    let title: String

    var body: some View {
        // A quiet divider rather than a bold tag: grey, at the previews'
        // size, with clear room above each group, like Codex and Claude.
        // Semibold so it isn't weaker than the rows it groups.
        Text(title)
            .font(.system(size: TypeScale.sidebarHeading, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.leading)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The scrolling part of each sidebar view: a lazy stack of rows with
/// up and down arrow keys once it has focus, as the system list had. Rows
/// are drawn here rather than in a `List` because the sidebar list style
/// paints its own accent-coloured selection, which can't be made as quiet
/// as the other agent apps' grey highlight.
private struct ThreadList<Content: View>: View {
    @Environment(AppModel.self) private var app
    /// Thread ids top to bottom, for the arrow keys.
    let order: [String]
    /// The id a thread's row has in the stack, to scroll it into view.
    var scrollID: (String) -> String = { $0 }
    @ViewBuilder let content: (_ select: @escaping (String) -> Void) -> Content
    @FocusState private var focused: Bool

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
                .padding(.horizontal, SidebarMetrics.outerInset)
                // Room for the last row to scroll clear of the fade below.
                .padding(.bottom, 32)
            }
            // With a mouse connected macOS draws a legacy scroller with a
            // track down the list, which also pushed the times left. Codex,
            // Claude and T3 show none; the list scrolls the same without it.
            .scrollIndicators(.never)
            // The last row fades into the footer rather than being cut
            // through its text at the hairline, as the transcript does above
            // the composer. About a title and a preview tall, and clear just
            // before the hairline: at 16 pt a row still showed half its
            // letters on the rule. A static mask, so scrolling costs nothing.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 30)
                    Color.clear.frame(height: 4)
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

/// Which list a row is in, for its hover buttons.
extension SidebarMode {
    var rowActions: [RowAction] {
        switch self {
        case .inbox: return [.snooze, .archive]
        case .snoozed: return [.unsnooze, .archive]
        case .archive: return [.unarchive]
        case .scheduled: return []
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
    let select: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    private var isSelected: Bool { app.selection == thread.id }
    /// The screenshot run shows one row as if the pointer were over it.
    private var showsActions: Bool { hovering || app.hoverOverride == thread.id }

    var body: some View {
        let look = mode == .inbox ? ThreadRowLook(thread, section: section) : ThreadRowLook(status: .time, unread: false, emphasised: false)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.system(size: TypeScale.sidebarTitle, weight: look.emphasised ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .overlay(alignment: .leading) {
                        if look.unread {
                            // In the row's leading gutter, centred on the title.
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .offset(x: -(SidebarMetrics.leading / 2 + 3.5))
                                .accessibilityLabel("Unread")
                        }
                    }
                Spacer(minLength: 6)
                if showsActions {
                    // Room for the hover buttons, drawn over the row so they
                    // don't change its height.
                    Color.clear.frame(width: CGFloat(mode.rowActions.count) * 24 - 6, height: 1)
                } else {
                    trailing(look)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let line = secondLine {
                    Text(line)
                        .font(.system(size: TypeScale.sidebarPreview))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // A new thread, or one that has only asked a question:
                    // a blank line here read as a gap in the list. "Waiting
                    // for your answer" is the row that most needs Mike, so
                    // it's never the faintest text in the sidebar.
                    Text(ThreadRowLook.emptyPreview(thread))
                        .font(.system(size: TypeScale.sidebarPreview))
                        .foregroundStyle(thread.status == .waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(SidebarMetrics.faint))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if app.showsAccountLabel(thread) {
                    Text(app.accountShortTitle(thread.accountId))
                        .font(.system(size: TypeScale.sidebarMeta))
                        .foregroundStyle(SidebarMetrics.faint)
                        .lineLimit(1)
                        .help(app.accountTitle(thread.accountId))
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: SidebarMetrics.leading, bottom: 8, trailing: SidebarMetrics.trailing))
        .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        // Selects on mouse down, as the system list did and Mail does; a
        // tap gesture waits for the mouse to come back up.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard !pressed else { return }
            pressed = true
            select()
        }.onEnded { _ in pressed = false })
        // After the gesture, so clicking these never selects the row.
        .overlay(alignment: .topTrailing) {
            if showsActions {
                RowActions(thread: thread, actions: mode.rowActions)
                    .padding(.top, 5)
                    .padding(.trailing, SidebarMetrics.trailing - 5)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { ThreadMenu(thread: thread) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return showsActions ? SidebarMetrics.hover : .clear
    }

    private var secondLine: String? {
        if mode == .snoozed, let until = thread.snoozedUntil {
            return "Back \(RelativeTime.until(until, now: app.now))"
        }
        let preview = PreviewText.plain(thread.preview)
        return preview.isEmpty ? nil : preview
    }

    @ViewBuilder
    private func trailing(_ look: ThreadRowLook) -> some View {
        switch look.status {
        case .time:
            if mode != .snoozed {
                time.foregroundStyle(SidebarMetrics.faint)
            }
        case .working:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // An accent arc turned in the render server (SpinnerView):
                // the system mini spinner drew grey whatever the tint, and
                // the symbol's variable colour left it a pale asterisk.
                SpinnerMark(color: .controlAccentColor)
                    .frame(width: 12, height: 12)
                    // On the text's baseline, centred on its lowercase.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                // How long the turn has run, ticking once a second. Only
                // running rows have this, and there are one to three.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = ThreadRowLook.workingLabel(since: thread.lastActivityAt, now: context.date)
                    Text(look.labelled ? "Working " + elapsed : elapsed).monospacedDigit()
                }
            }
            .font(.system(size: TypeScale.sidebarMeta, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .help("Working")
        case .background:
            // Still being worked on, but by sub-agents or jobs in the
            // background: the same spinner in grey, and what's running
            // instead of a clock. Visibly not a streaming turn.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                SpinnerMark(color: .secondaryLabelColor)
                    .frame(width: 12, height: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(BackgroundWork.short(thread.background))
            }
            .font(.system(size: TypeScale.sidebarMeta, weight: .medium))
            .foregroundStyle(.secondary)
            .help(BackgroundWork.detail(thread.background))
        case .needsYou:
            if look.labelled {
                Text("Needs you").font(.system(size: TypeScale.sidebarMeta, weight: .medium)).foregroundStyle(Color(nsColor: Theme.needsYou))
            } else {
                // Under the Needs you heading: how long it has been waiting.
                time.fontWeight(.medium).foregroundStyle(Color(nsColor: Theme.needsYou))
                    .help("Waiting for you")
            }
        case .failed:
            Text("Failed").font(.system(size: TypeScale.sidebarMeta, weight: .medium)).foregroundStyle(Color(nsColor: Theme.failed))
                .help("The last turn failed")
        case .stopped:
            Text("Stopped").font(.system(size: TypeScale.sidebarMeta)).foregroundStyle(.secondary)
                .help("Stopped when the runner restarted")
        }
    }

    /// When the thread was last active (archived, in the archive).
    private var time: Text {
        Text(RelativeTime.short(mode == .archive ? thread.archivedAt ?? thread.lastActivityAt : thread.lastActivityAt, now: app.now))
            .font(.system(size: TypeScale.sidebarMeta))
            .monospacedDigit()
    }
}

/// The small buttons a row shows on hover in place of its time.
private struct RowActions: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let actions: [RowAction]

    var body: some View {
        HStack(spacing: 2) {
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
                    .help("Hibernate")
                case .archive:
                    Button {
                        guard BusyConfirm.allowed(.archive, threadId: thread.id, app: app) else { return }
                        app.archive(thread.id)
                    } label: { Image(systemName: "archivebox") }
                        .buttonStyle(RowIconButtonStyle())
                        .help("Archive (⌘E)")
                case .unsnooze:
                    Button { app.unsnooze(thread.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(RowIconButtonStyle())
                        .help("Wake")
                case .unarchive:
                    Button { app.unarchive(thread.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(RowIconButtonStyle())
                        .help("Unarchive")
                }
            }
        }
    }
}

/// A 22 pt borderless icon button with its own faint hover square.
struct RowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowIconButton(configuration: configuration)
    }

    private struct RowIconButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A full-width sidebar row that does one thing: New thread at the top,
/// Hibernating and Archive at the bottom.
struct SidebarButtonRow: View {
    let icon: String
    /// Drawn instead of the symbol when set (the bear in the footer).
    var image: NSImage? = nil
    let title: String
    var hint: String? = nil
    var count: Int? = nil
    var active = false
    var size: CGFloat = TypeScale.sidebarButton
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let image {
                    // The bear, drawn in the same grey as the symbols.
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .frame(width: 16)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                // The footer's rows are navigation, quieter than the threads
                // above them; New thread stays primary.
                Text(title)
                    .font(.system(size: size))
                    .foregroundStyle(size < TypeScale.sidebarButton ? .secondary : .primary)
                Spacer(minLength: 6)
                if let hint {
                    Text(hint).font(.system(size: TypeScale.sidebarMeta)).foregroundStyle(SidebarMetrics.faint)
                }
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: size)).foregroundStyle(SidebarMetrics.faint).monospacedDigit()
                }
            }
            // The icon sits where thread titles start, Codex style.
            .padding(.leading, SidebarMetrics.leading - 2)
            .padding(.trailing, SidebarMetrics.trailing)
            .padding(.vertical, size >= TypeScale.sidebarButton ? 7 : 6)
            .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if active { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return hovering ? SidebarMetrics.hover : .clear
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            SidebarButtonRow(icon: "moon.zzz", image: Bear.image(.sleep), title: "Hibernating", count: app.snoozed.count, size: TypeScale.sidebarFooter) {
                app.sidebarMode = .snoozed
            }
            SidebarButtonRow(icon: "archivebox", title: "Archive", count: app.archiveLoaded ? app.archivedCount : nil, size: TypeScale.sidebarFooter) {
                app.showArchive()
            }
            // Only once the runner has said it knows about schedules.
            if app.schedulesSupported {
                SidebarButtonRow(icon: "clock", title: "Scheduled", count: app.activeScheduleCount, size: TypeScale.sidebarFooter) {
                    app.showSchedules()
                }
            }
            UsageButton()
        }
        .padding(.horizontal, SidebarMetrics.outerInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 0.5).padding(.horizontal, SidebarMetrics.outerInset + 10)
        }
    }
}

/// "Usage": every account's room and the CLIs' versions, in a popover.
private struct UsageButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        SidebarButtonRow(icon: "gauge.with.dots.needle.33percent", title: "Usage", size: TypeScale.sidebarFooter) {
            app.usagePopoverShown.toggle()
        }
        // On the model, so a script can open it and `dump` can say so.
        // Above the button, which sits at the foot of the window.
        .popover(isPresented: $app.usagePopoverShown, arrowEdge: .top) {
            UsagePopover().environment(app)
        }
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
                .padding(.top, 4)
                .padding(.bottom, 6)
            ThreadList(order: archived.map(\.id)) { select in
                ForEach(archived) { thread in
                    ThreadRowView(thread: thread, mode: .archive) { select(thread.id) }
                        .id(thread.id)
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
            .padding(.top, 10)
    }
}

/// The top of the Snoozed and Archive views, where New thread is in the
/// inbox: a back button, the view's name and its count.
struct ModeHeader: View {
    @Environment(AppModel.self) private var app
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                app.sidebarMode = .inbox
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Back to the inbox (Esc)")
            Text(title)
                .font(.system(size: TypeScale.sidebarButton, weight: .semibold))
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.system(size: TypeScale.sidebarFooter)).foregroundStyle(SidebarMetrics.faint).monospacedDigit()
            }
        }
        // The chevron's glyph lines up with the icons and titles below.
        .padding(.leading, SidebarMetrics.outerInset + SidebarMetrics.leading - 8)
        .padding(.trailing, SidebarMetrics.outerInset + SidebarMetrics.trailing)
        .padding(.top, 4)
        .frame(height: 34)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        // The glass and the prompt on the same columns as New thread's icon
        // and title, as SidebarButtonRow lays them out.
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(SidebarMetrics.faint)
                .frame(width: 16)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.sidebarButton))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.leading, SidebarMetrics.leading - 2)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
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
