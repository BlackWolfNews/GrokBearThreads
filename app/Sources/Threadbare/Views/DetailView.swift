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

    var body: some View {
        let thread = app.selectedThread
        let session = app.selection.map { app.session(for: $0) }
        VStack(spacing: 0) {
            ConnectionBanner()
            ErrorBanner()
            if let thread, thread.isArchived {
                ArchivedBar(thread: thread)
            }
            ZStack {
                TranscriptView(session: session, controller: app.transcript)
                if app.selection == nil {
                    NewThreadPlaceholder()
                } else if let session, session.state == .loading, session.displayCount == 0 {
                    ProgressView().controlSize(.small)
                } else if let session, case .failed(let message) = session.state {
                    VStack(spacing: 8) {
                        Text("Couldn't load this thread.").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                        Button("Try again") { app.select(session.threadId) }
                    }
                }
            }
            ComposerView(thread: thread)
        }
        .navigationTitle(thread?.title ?? "New thread")
        .navigationSubtitle(thread.map { $0.cwd.abbreviatingHome } ?? "")
        .toolbar {
            // Always there, disabled with no thread selected: building the
            // toolbar items on the first selection cost about 40 ms of that
            // first open (NSToolbarView layout), on top of the transcript.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if let thread {
                        ForEach(Snooze.presets(now: app.now)) { preset in
                            Button(preset.title) { app.snooze(thread.id, until: Snooze.date(for: preset.id, now: Date())) }
                        }
                        Divider()
                        Button("Pick a time…") { SnoozePicker.show(threadId: thread.id, app: app) }
                    }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .help("Snooze")
                .disabled(thread == nil)
                Button {
                    guard let thread else { return }
                    if thread.isArchived { app.unarchive(thread.id) } else { app.archive(thread.id) }
                } label: {
                    if thread?.isArchived == true {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    } else {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
                .help(thread?.isArchived == true ? "Unarchive" : "Archive (⌘E)")
                .disabled(thread == nil)
                Menu {
                    Button("Copy transcript as Markdown") { session?.copyTranscript() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(thread == nil)
            }
        }
    }
}

private struct NewThreadPlaceholder: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            Text("New thread").font(.title2.weight(.semibold))
            Text("Starts in \((app.newThreadCwd ?? app.defaults.cwd).abbreviatingHome) on \(app.accountTitle(app.newThreadAccount ?? app.lastAccountId)).")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
    }
}

private struct ArchivedBar: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        HStack {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            Text("This thread is archived.")
            Spacer()
            Button("Unarchive") { app.unarchive(thread.id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
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
