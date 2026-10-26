import AppKit
import SwiftUI
import ThreadbareCore

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 420)
        } detail: {
            DetailView()
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var app
    /// The pane's width in 20 pt steps, to cap the header's width so a long
    /// title truncates instead of going into the toolbar's overflow menu.
    /// Stepped so a live resize re-renders this view a few times, not on
    /// every frame.
    @State private var widthStep: CGFloat = 900
    /// The legacy scroller's width the transcript keeps free on its right,
    /// so the composer centres under the same reading column. Only changes
    /// with the system's scroll bar setting (or a mouse coming and going).
    @State private var scrollerReserve: CGFloat = 0

    var body: some View {
        let thread = app.selectedThread
        let session = app.selection.map { app.session(for: $0) }
        let isNew = app.selection == nil
        VStack(spacing: 0) {
            ConnectionBanner()
            ErrorBanner()
            ComposerPlacement(centred: isNew, trailingReserve: scrollerReserve) {
                ZStack {
                    TranscriptView(session: session, controller: app.transcript)
                    if let session, session.state == .loading, session.displayCount == 0 {
                        ProgressView().controlSize(.small)
                    } else if let session, case .failed(let message) = session.state {
                        VStack(spacing: 8) {
                            Text("Couldn't load this thread.").font(.headline)
                            Text(message).foregroundStyle(.secondary)
                            Button("Try again") { app.select(session.threadId) }
                        }
                    }
                }
                .layoutValue(key: PaneRole.self, value: .transcript)
                ComposerView(thread: thread)
                    .layoutValue(key: PaneRole.self, value: .composer)
                if isNew {
                    NewThreadHeading()
                        .layoutValue(key: PaneRole.self, value: .heading)
                    NewThreadNote()
                        .layoutValue(key: PaneRole.self, value: .note)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded(.down) * 20 } action: { widthStep = $0 }
        .onAppear { scrollerReserve = app.transcript.reservedScrollerWidth }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            // With a mouse connected AppKit switches to legacy scrollers a
            // moment after launch (onAppear still sees overlay), and again
            // whenever the setting changes. Read it once the scroll views
            // have taken up the new style.
            DispatchQueue.main.async { scrollerReserve = app.transcript.reservedScrollerWidth }
        }
        // The window's title (Window menu, Mission Control); the toolbar
        // shows the header below instead.
        .navigationTitle(thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "New thread")
        .toolbar(removing: .title)
        .toolbar {
            // Both items are always there, the header empty and the menu
            // disabled with no thread selected: building toolbar items on
            // the first selection cost about 40 ms of that first open
            // (NSToolbarView layout), on top of the transcript.
            ToolbarItem(placement: .navigation) {
                HeaderTitle(thread: thread)
                    .frame(maxWidth: max(120, widthStep - 120), alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            // With the system title gone nothing pushes the menu to the
            // trailing edge; it sat right after the header.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let thread {
                        ThreadMenu(thread: thread)
                        Divider()
                        Button("Copy transcript as Markdown") { session?.copyTranscript() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More")
                .disabled(thread == nil)
                // Still built (see above), but out of sight with nothing to
                // act on: a dimmed "..." alone in an empty new thread's
                // header looked broken.
                .opacity(thread == nil ? 0 : 1)
                .allowsHitTesting(thread != nil)
            }
            // A plain glyph like Codex's and Claude's. Its glass disc drew
            // dark grey on a light window.
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// One line, T3 style: the folder's name, then the title, and "Archived"
/// for an archived thread. The full path is in the tooltip.
private struct HeaderTitle: View {
    let thread: ThreadSummary?

    var body: some View {
        if let thread {
            HStack(spacing: 5) {
                Text(FolderName.short(thread.cwd))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text("/")
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if thread.isArchived {
                    // A quiet word here rather than a full-width band under
                    // the header, which nothing else in the window had.
                    // Unarchive is in the ... menu, ⌘E and the row's hover
                    // button.
                    Text("·  Archived").foregroundStyle(.tertiary).layoutPriority(1)
                }
            }
            .font(.system(size: TypeScale.header))
            .lineLimit(1)
            .padding(.leading, 6)
            .help(thread.cwd.abbreviatingHome)
        } else {
            Color.clear.frame(width: 1, height: 1)
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
    /// Kept free at the right under a thread, where the transcript keeps
    /// room for a legacy scroller, so the composer card lines up with the
    /// reading column above it. A new thread has no column to line up
    /// with, so it centres in the whole pane like its heading.
    var trailingReserve: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func find(_ role: PaneRole.Role) -> LayoutSubview? { subviews.first { $0[PaneRole.self] == role } }
        let width = ProposedViewSize(width: bounds.width, height: nil)
        let composerWidth = centred ? bounds.width : max(0, bounds.width - trailingReserve)
        let composerHeight = find(.composer)?.sizeThatFits(ProposedViewSize(width: composerWidth, height: nil)).height ?? 0
        let transcriptHeight = max(0, bounds.height - composerHeight)
        find(.transcript)?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: transcriptHeight))

        let heading = centred ? find(.heading) : nil
        let note = centred ? find(.note) : nil
        let composerY = bounds.minY + ComposerPlacementMath.composerTop(
            paneHeight: bounds.height, composerHeight: composerHeight, centred: centred,
            headingHeight: Double(heading?.sizeThatFits(width).height ?? 0), noteHeight: Double(note?.sizeThatFits(width).height ?? 0)
        )
        heading?.place(at: CGPoint(x: bounds.minX, y: composerY - 18), anchor: .bottomLeading, proposal: width)
        note?.place(at: CGPoint(x: bounds.minX, y: composerY + composerHeight - 2), proposal: width)
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
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
    }
}

/// "Starts in misc on cannstudios": the folder and account the composer's
/// menus are set to.
private struct NewThreadNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let cwd = app.newThreadCwd ?? app.defaults.cwd
        let account = app.newThreadAccount ?? app.lastAccountId
        Text("Starts in \(FolderName.short(cwd)) on \(app.accountShortTitle(account))")
            .font(.system(size: TypeScale.label))
            .foregroundStyle(.tertiary)
            .help("\(cwd.abbreviatingHome) on \(app.accountTitle(account))")
            .frame(maxWidth: .infinity)
    }
}

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.connection {
        case .connected:
            EmptyView()
        case .connecting:
            banner(icon: "bolt.horizontal", text: "Connecting to the runner…", showStart: false)
        case .runnerDown(let reason):
            // One plain sentence; the raw reason is in the tooltip.
            banner(icon: "bolt.horizontal.circle", text: "Can't reach the runner.", detail: reason, showStart: true)
        case .lost:
            banner(icon: "bolt.horizontal", text: "Lost the connection to the runner. Reconnecting…", showStart: false)
        case .unauthorized:
            banner(icon: "lock", text: "The runner didn't accept the token in secrets/runner-token.", showStart: false)
        }
    }

    private func banner(icon: String, text: String, detail: String? = nil, showStart: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).lineLimit(2).help(detail ?? "")
            Spacer()
            if showStart {
                Button("Start runner") { app.startRunner() }
            }
            Button("Try again") { app.reconnectNow() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.1))
        }
    }
}
