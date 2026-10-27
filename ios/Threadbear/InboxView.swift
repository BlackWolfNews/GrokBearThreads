import SwiftUI
import ThreadbearKit

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var composing = false
    @State private var hibernateTarget: PhoneThread?

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label { Text("Nothing in the inbox") } icon: { BearView(pose: .sit, size: 44) }
                    } description: {
                        Text("Threads that finish or need you turn up here.")
                    }
                    .listRowBackground(Color.clear)
                }
                if !sections.inbox.isEmpty {
                    Section("Inbox") { rows(sections.inbox) }
                }
                if !sections.running.isEmpty {
                    Section("Running") { rows(sections.running) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Threadbear")
            .navigationDestination(for: String.self) { ThreadView(threadId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        NavigationLink { ThreadListView(title: "Hibernating", view: .hibernating) } label: {
                            Label("Hibernating (\(model.hibernating.count))", systemImage: "moon.zzz")
                        }
                        NavigationLink { ThreadListView(title: "Den", view: .den) } label: {
                            Label("Den", systemImage: "archivebox")
                        }
                        NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New thread")
                }
            }
            .sheet(isPresented: $composing) {
                NewThreadView { threadId in path.append(threadId) }
            }
            .hibernateDialog(for: $hibernateTarget)
            .refreshable { try? await Task.sleep(for: .milliseconds(400)) }
            .overlay(alignment: .bottom) { ConnectionToast() }
            .onChange(of: model.openThreadId, initial: true) { _, id in
                guard let id else { return }
                path = [id]
                model.openThreadId = nil
            }
        }
    }

    @ViewBuilder private func rows(_ threads: [PhoneThread]) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.threadId) {
                ThreadRow(thread: thread)
            }
            .swipeActions(edge: .trailing) {
                Button { Task { await perform(thread, .archive) } } label: { Label("Den", systemImage: "archivebox") }
                    .tint(.brown)
            }
            .swipeActions(edge: .leading) {
                Button { hibernateTarget = thread } label: { Label("Hibernate", systemImage: "moon.zzz") }
                    .tint(.indigo)
            }
            .contextMenu {
                Button { hibernateTarget = thread } label: { Label("Hibernate…", systemImage: "moon.zzz") }
                Button { Task { await perform(thread, .archive) } } label: { Label("Put in the Den", systemImage: "archivebox") }
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

/// Hibernating or the Den: a plain list, newest first, with a way back.
struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    var title: String
    var view: ThreadsView

    var body: some View {
        let threads = view == .den ? model.den : model.hibernating
        List {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label { Text(view == .den ? "The Den's empty" : "Nobody's hibernating") } icon: {
                        BearView(pose: .sleep, size: 44)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(threads) { thread in
                NavigationLink(value: thread.threadId) { ThreadRow(thread: thread) }
                    .swipeActions(edge: .trailing) {
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
        .navigationTitle(title)
    }
}

struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    var thread: PhoneThread

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProjectTile(thread: thread)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title)
                        .font(.body.weight(emphasised ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(RowStatus.text(thread, now: model.now))
                        .font(.footnote.weight(InboxSections.needsAnswer(thread) ? .semibold : .regular))
                        .foregroundStyle(InboxSections.needsAnswer(thread) ? Color.accentColor : .secondary)
                }
                HStack(spacing: 6) {
                    if emphasised {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    Text(line2)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var emphasised: Bool { thread.unread || thread.needsYou || InboxSections.needsAnswer(thread) }

    private var line2: String {
        var parts = [thread.placeText]
        if let runner = model.runnerName(thread.runnerId) { parts.append(runner) }
        if let working = thread.working, thread.isBusy || thread.pendingApproval == nil { parts.append(working) }
        return parts.joined(separator: " · ")
    }
}

/// The first letter of the thread's project, or a folder for a thread in
/// none, as on the Mac sidebar.
struct ProjectTile: View {
    var thread: PhoneThread

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: 34, height: 34)
            .overlay {
                if let first = thread.projects?.first?.title.first {
                    Text(String(first).uppercased()).font(.headline).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "folder").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
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
