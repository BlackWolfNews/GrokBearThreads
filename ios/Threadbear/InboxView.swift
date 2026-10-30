import SwiftUI
import ThreadbearKit

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuickAskModel.self) private var quick
    @State private var path: [String] = []
    @State private var composing = false
    @State private var composeText = ""
    @State private var hibernateTarget: PhoneThread?
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = model.backendProblem {
                    Section {
                        Label(problem, systemImage: "arrow.down.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let offline = model.offlineText {
                    Section {
                        Label(offline, systemImage: "moon.zzz")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Anything you send waits until it's back.")
                    }
                }
                let sections = model.sections
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    results(ThreadSearch(query, sections: sections, hibernating: model.hibernating, archived: model.den))
                } else if !model.loaded.contains(.inbox) {
                    LoadingRows()
                } else if sections.isEmpty {
                    ContentUnavailableView {
                        Label { Text("Nothing in the inbox") } icon: { BearView(pose: .sit, size: 44) }
                    } description: {
                        Text("Threads that finish or need you turn up here.")
                    }
                    .listRowBackground(Color.clear)
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !sections.inbox.isEmpty {
                        Section { rows(sections.inbox) } header: { SectionHeading(title: "Inbox", icon: "tray") }
                    }
                    if !sections.running.isEmpty {
                        Section { rows(sections.running, running: true) } header: { SectionHeading(title: "Running", icon: "bolt") }
                    }
                    if !sections.waiting.isEmpty {
                        Section { rows(sections.waiting, waiting: true) } header: { SectionHeading(title: "Waiting", icon: "clock") }
                    }
                }
            }
            // A flat list with the Mac sidebar's headings, not grouped cards.
            .listStyle(.plain)
            .listSectionSeparator(.hidden)
            .navigationTitle("Threadbear")
            // Always showing, rather than tucked under the title until you
            // pull down: on the phone it's the quickest way to an old thread.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationDestination(for: String.self) { ThreadView(threadId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        NavigationLink { ThreadListView(title: "Hibernating", view: .hibernating) } label: {
                            Label("Hibernating (\(model.hibernating.count))", systemImage: "moon.zzz")
                        }
                        NavigationLink { ThreadListView(title: "Archived", view: .den) } label: {
                            Label("Archived", systemImage: "archivebox")
                        }
                        NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
                        if model.isFake {
                            Button { model.leaveDemo() } label: {
                                Label("Leave the demo", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                if quick.settings.isReady {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { quick.open() } label: { Image(systemName: "waveform") }
                            .accessibilityLabel("Ask")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New thread")
                }
            }
            .sheet(isPresented: $composing, onDismiss: { composeText = "" }) {
                NewThreadView(text: composeText) { threadId in path.append(threadId) }
            }
            .onChange(of: model.composeText, initial: true) { _, text in
                guard let text else { return }
                composeText = text
                composing = true
                model.composeText = nil
            }
            .hibernateDialog(for: $hibernateTarget)
            .refreshable { try? await Task.sleep(for: .milliseconds(400)) }
            .overlay(alignment: .bottom) { ConnectionToast() }
            .onChange(of: model.searchText, initial: true) { _, text in
                guard let text else { return }
                query = text
                model.searchText = nil
            }
            .onChange(of: model.openThreadId, initial: true) { _, id in
                guard let id else { return }
                path = [id]
                model.openThreadId = nil
            }
        }
    }

    /// What the search found, under the same headings as the Mac's sidebar,
    /// the put-away threads too.
    @ViewBuilder private func results(_ search: ThreadSearch) -> some View {
        if search.isEmpty {
            ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if !search.inbox.isEmpty {
            Section { rows(search.inbox) } header: { SectionHeading(title: "Inbox", icon: "tray") }
        }
        if !search.running.isEmpty {
            Section { rows(search.running, running: true) } header: { SectionHeading(title: "Running", icon: "bolt") }
        }
        if !search.waiting.isEmpty {
            Section { rows(search.waiting, waiting: true) } header: { SectionHeading(title: "Waiting", icon: "clock") }
        }
        if !search.hibernating.isEmpty {
            Section { putAwayRows(search.hibernating, from: .hibernating) } header: { SectionHeading(title: "Hibernating", icon: "moon.zzz") }
        }
        if !search.archived.isEmpty {
            Section { putAwayRows(search.archived, from: .den) } header: { SectionHeading(title: "Archived", icon: "archivebox") }
        }
    }

    /// Hibernating or archived rows found by the search: open on a tap, and
    /// swipe to bring back, as in their own lists.
    private func putAwayRows(_ threads: [PhoneThread], from view: ThreadsView) -> some View {
        ForEach(threads) { thread in
            Button { path.append(thread.threadId) } label: { ThreadRow(thread: thread) }
                .buttonStyle(.plain)
                .listRowInsets(ThreadRow.insets)
                .listRowSeparator(.hidden)
                .bringBackSwipe(thread, from: view)
        }
    }

    @ViewBuilder private func rows(_ threads: [PhoneThread], running: Bool = false, waiting: Bool = false) -> some View {
        ForEach(threads) { thread in
            // A plain row, not a NavigationLink: the Mac's rows have no
            // chevron, and the status sits where it would go.
            Button { path.append(thread.threadId) } label: {
                ThreadRow(thread: thread, underRunning: running, wake: waiting ? model.wakes[thread.threadId] : nil)
            }
            .buttonStyle(.plain)
            .listRowInsets(ThreadRow.insets)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing) {
                Button { Task { await perform(thread, .archive) } } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(.brown)
            }
            .swipeActions(edge: .leading) {
                Button { hibernateTarget = thread } label: { Label("Hibernate", systemImage: "moon.zzz") }
                    .tint(.indigo)
            }
            .contextMenu {
                Button { hibernateTarget = thread } label: { Label("Hibernate…", systemImage: "moon.zzz") }
                Button { Task { await perform(thread, .archive) } } label: { Label("Archive", systemImage: "archivebox") }
                if thread.unread || thread.needsYou {
                    Button { Task { await perform(thread, .markSeen) } } label: { Label("Mark as read", systemImage: "envelope.open") }
                }
            }
        }
    }

    private func perform(_ thread: PhoneThread, _ change: ThreadChange) async {
        guard let backend = model.backend else { return }
        do { _ = try await backend.update(threadId: thread.threadId, change: change) } catch { model.report(error) }
    }
}

/// Hibernating or Archived: a plain list, newest first, with a way back.
struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    var title: String
    var view: ThreadsView

    var body: some View {
        let threads = view == .den ? model.den : model.hibernating
        List {
            if !model.loaded.contains(view) {
                LoadingRows(count: 4)
            } else if threads.isEmpty {
                ContentUnavailableView {
                    Label { Text(view == .den ? "Nothing archived" : "Nobody's hibernating") } icon: {
                        BearView(pose: .sleep, size: 44)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(threads) { thread in
                NavigationLink(value: thread.threadId) { ThreadRow(thread: thread) }
                    .listRowInsets(ThreadRow.insets)
                    .listRowSeparator(.hidden)
                    .bringBackSwipe(thread, from: view)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

extension View {
    /// Wake a hibernating thread, or put an archived one back in the inbox.
    func bringBackSwipe(_ thread: PhoneThread, from view: ThreadsView) -> some View {
        modifier(BringBackSwipe(thread: thread, view: view))
    }
}

private struct BringBackSwipe: ViewModifier {
    @Environment(AppModel.self) private var model
    var thread: PhoneThread
    var view: ThreadsView

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing) {
            Button {
                Task {
                    guard let backend = model.backend else { return }
                    do { _ = try await backend.update(threadId: thread.threadId, change: view == .den ? .unarchive : .wake) }
                    catch { model.report(error) }
                }
            } label: {
                Label(view == .den ? "Back to inbox" : "Wake", systemImage: view == .den ? "tray.and.arrow.up" : "sun.max")
            }
            .tint(.accentColor)
        }
    }
}

/// A row as the Mac sidebar draws one: the project's tile two lines tall,
/// the title across the width, and under it where the thread belongs and
/// what it's doing, with the unread dot (or the done tick) in the gutter
/// left of the tile.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    var thread: PhoneThread
    /// Under the Running heading a working row shows just its spinner and
    /// time, as on the Mac: the heading says what it's doing.
    var underRunning = false
    /// Under the Waiting heading, the schedule that messages it next: the
    /// row says when, where the time would be, as on the Mac.
    var wake: PhoneSchedule?

    /// Room on the left for the gutter mark; the trailing edge like the Mac's.
    static let insets = EdgeInsets(top: 6, leading: 28, bottom: 6, trailing: 16)

    var body: some View {
        let kind = RowStatus.kind(thread)
        HStack(alignment: .center, spacing: 10) {
            ProjectTiles(projects: thread.projects ?? [])
                .overlay(alignment: .leading) {
                    if done {
                        // Finished with nothing needed: a tick where the
                        // unread dot would be.
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .offset(x: -19)
                            .accessibilityLabel("Done, unread")
                    } else if unread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: -17)
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.body.weight(emphasised ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line2)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    trailing(kind)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The Mac's ThreadRowLook, as far as the phone's row knows: unread
    /// with nothing waiting on Mike is "done" (a tick); unread and needing
    /// him, a dot, unless the status already says so in words.
    private var done: Bool { RowStatus.kind(thread) == .time && thread.unread && !thread.needsYou }
    private var unread: Bool {
        let kind = RowStatus.kind(thread)
        return (thread.needsYou && kind != .needsYou && kind != .working) || done
    }
    private var emphasised: Bool { thread.needsYou || RowStatus.kind(thread) == .needsYou || done }

    private var line2: String {
        var parts = [thread.placeText]
        if let runner = model.runnerName(thread.runnerId) { parts.append(runner) }
        if let working = thread.working, thread.isBusy || thread.pendingApproval == nil { parts.append(working) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func trailing(_ kind: RowStatus.Kind) -> some View {
        switch kind {
        case .working:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.accentColor)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                // How long the turn has run, ticking once a second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = RowStatus.workingLabel(since: thread.lastActivityAt, now: context.date)
                    Text(underRunning ? elapsed : "Working " + elapsed)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.default, value: elapsed)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.accentColor)
        case .needsYou:
            Text("Needs you").font(.footnote.weight(.medium)).foregroundStyle(Look.needsYou)
        case .failed:
            Text("Failed").font(.footnote.weight(.medium)).foregroundStyle(Look.failed)
        case .stopped:
            Text("Stopped").font(.footnote).foregroundStyle(.secondary)
        case .time where thread.woke != nil:
            // Back from hibernating by itself; the time comes back once
            // it's been opened.
            Text(RowStatus.text(thread, now: model.now)).font(.footnote.weight(.medium)).foregroundStyle(Color.accentColor)
        case .time where wake?.nextRunAt != nil:
            // When its schedule messages it next: "10:42", "Mon 10:42".
            Text(RelativeTime.clock(wake?.nextRunAt ?? model.now, now: model.now))
                .font(.footnote).monospacedDigit().foregroundStyle(Look.faint)
                .accessibilityLabel("Scheduled: \(wake?.whenText ?? "")")
        case .time:
            Text(RowStatus.text(thread, now: model.now)).font(.footnote).monospacedDigit().foregroundStyle(Look.faint)
        }
    }
}

/// A small note at the bottom when Convex can't be reached, or a call failed.
struct ConnectionToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.connected {
                toast("Reconnecting…", icon: "wifi.slash")
            } else if let error = model.lastError {
                toast(error, icon: "exclamationmark.triangle")
                    .onTapGesture { model.clearError() }
                    .task(id: error) {
                        try? await Task.sleep(for: .seconds(6))
                        model.clearError()
                    }
            }
        }
        .animation(.default, value: model.connected)
        .animation(.default, value: model.lastError)
    }

    private func toast(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// The Hibernate presets as a dialog, for a swipe or a menu.
    func hibernateDialog(for target: Binding<PhoneThread?>) -> some View {
        modifier(HibernateDialog(target: target))
    }
}

private struct HibernateDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var target: PhoneThread?

    func body(content: Content) -> some View {
        content.confirmationDialog("Hibernate until", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                   titleVisibility: .visible, presenting: target) { thread in
            ForEach(Hibernate.presets(now: .now)) { preset in
                Button(preset.title) { change(thread, .snooze(until: preset.date)) }
            }
            Button("Until the runner restarts") { change(thread, .snoozeUntilRestart) }
        }
    }

    private func change(_ thread: PhoneThread, _ change: ThreadChange) {
        Task {
            guard let backend = model.backend else { return }
            do { _ = try await backend.update(threadId: thread.threadId, change: change) } catch { model.report(error) }
        }
    }
}

/// Grey placeholder rows, shaped like thread rows, while a list waits for
/// its first answer from Convex, so a list that's loading doesn't look
/// empty.
struct LoadingRows: View {
    var count = 6
    @State private var dim = false

    var body: some View {
        ForEach(0..<count, id: \.self) { i in
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 5).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 7) {
                    // Varied widths, so it reads as rows of titles rather than bars.
                    Capsule().frame(width: [190, 150, 220, 170, 130, 200][i % 6], height: 11)
                    Capsule().frame(width: [110, 90, 130, 80, 120, 100][i % 6], height: 9)
                }
                Spacer()
                Capsule().frame(width: 24, height: 9)
            }
            .foregroundStyle(Color(.tertiarySystemFill))
            .opacity(dim ? 0.45 : 1)
            .listRowInsets(ThreadRow.insets)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading threads")
    }
}
