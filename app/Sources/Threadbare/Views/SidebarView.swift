import AppKit
import SwiftUI
import ThreadbareCore

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.sidebarMode {
        case .inbox: InboxList()
        case .snoozed: SnoozedList()
        case .archive: ArchiveList()
        }
    }
}

private struct InboxList: View {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        let selection = Binding<String?>(get: { app.selection }, set: { app.select($0) })
        VStack(spacing: 0) {
            SearchField(text: $app.searchText, prompt: "Search threads")
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            List(selection: selection) {
                if let results = app.searchResults {
                    Section("Results") {
                        ForEach(results) { thread in
                            ThreadRowView(thread: thread).tag(thread.id)
                        }
                        if results.isEmpty {
                            Text("No threads match.").foregroundStyle(.secondary)
                        }
                    }
                } else if app.threadsLoaded {
                    let sections = app.sections
                    if !sections.needsYou.isEmpty {
                        Section("Needs you") {
                            ForEach(sections.needsYou) { ThreadRowView(thread: $0).tag($0.id) }
                        }
                    }
                    if !sections.running.isEmpty {
                        Section("Running") {
                            ForEach(sections.running) { ThreadRowView(thread: $0).tag($0.id) }
                        }
                    }
                    Section("Inbox") {
                        ForEach(sections.inbox) { ThreadRowView(thread: $0).tag($0.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarFooter()
            }
        }
        .onChange(of: app.focusSearch) { _, focus in
            if focus {
                searchFocused = true
                app.focusSearch = false
            }
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            Button {
                app.sidebarMode = .snoozed
            } label: {
                Label(app.snoozed.isEmpty ? "Snoozed" : "Snoozed (\(app.snoozed.count))", systemImage: "moon.zzz")
            }
            Button {
                app.sidebarMode = .archive
                app.loadArchive()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ThreadRowView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(thread: thread)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(.body.weight(thread.needsYou ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(thread.lastActivityAt, now: app.now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(thread.preview.isEmpty ? " " : PreviewText.plain(thread.preview))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if app.showsAccountBadge(thread) {
                        Spacer(minLength: 0)
                        Text(app.accountShortTitle(thread.accountId))
                            .lineLimit(1)
                            .help(app.accountTitle(thread.accountId))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu { ThreadMenu(thread: thread) }
    }
}

struct StatusDot: View {
    let thread: ThreadSummary

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(color == .clear ? 0 : 1)
            .help(help)
    }

    private var color: Color {
        switch thread.status {
        case .waiting: return .orange
        case .running, .starting: return .blue
        case .error: return .red
        case .stopped: return .gray
        case .idle: return thread.needsYou ? .accentColor : .clear
        }
    }

    private var help: String {
        switch thread.status {
        case .waiting: return "Waiting for you"
        case .running, .starting: return "Running"
        case .error: return "The last turn failed"
        case .stopped: return "Stopped when the runner restarted"
        case .idle: return thread.needsYou ? "Unread" : ""
        }
    }
}

/// Snooze, archive and copy, shared by the context menu and the toolbar.
struct ThreadMenu: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        SnoozeMenu(threadId: thread.id)
        if thread.isArchived {
            Button("Unarchive") { app.unarchive(thread.id) }
        } else {
            Button("Archive") { app.archive(thread.id) }
        }
        if thread.snoozedUntil != nil {
            Button("Unsnooze") { app.unsnooze(thread.id) }
        }
    }
}

struct SnoozeMenu: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    @State private var picking = false

    var body: some View {
        Menu("Snooze") {
            ForEach(Snooze.presets(now: app.now)) { preset in
                Button(preset.title) { app.snooze(threadId, until: Snooze.date(for: preset.id, now: Date())) }
            }
            Divider()
            Button("Pick a time…") { SnoozePicker.show(threadId: threadId, app: app) }
        }
    }
}

private struct SnoozedList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let selection = Binding<String?>(get: { app.selection }, set: { app.select($0) })
        VStack(spacing: 0) {
            ModeHeader(title: "Snoozed")
            List(selection: selection) {
                ForEach(app.snoozed) { thread in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title).lineLimit(1)
                            Text("Back \(RelativeTime.until(thread.snoozedUntil ?? Date(), now: app.now))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unsnooze") { app.unsnooze(thread.id) }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                    .padding(.vertical, 3)
                    .tag(thread.id)
                    .contextMenu { ThreadMenu(thread: thread) }
                }
                if app.snoozed.isEmpty {
                    Text("Nothing snoozed.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct ArchiveList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let selection = Binding<String?>(get: { app.selection }, set: { app.select($0) })
        VStack(spacing: 0) {
            ModeHeader(title: "Archive")
            SearchField(text: $app.archiveQuery, prompt: "Search the archive")
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            List(selection: selection) {
                ForEach(app.archived) { thread in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title).lineLimit(1)
                            Text(thread.preview.isEmpty ? " " : PreviewText.plain(thread.preview))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Unarchive") { app.unarchive(thread.id) }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                    .padding(.vertical, 3)
                    .tag(thread.id)
                    .contextMenu { ThreadMenu(thread: thread) }
                }
                if app.archived.isEmpty {
                    Text(app.archiveLoaded ? "Nothing archived matches." : "Loading…").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct ModeHeader: View {
    @Environment(AppModel.self) private var app
    let title: String

    var body: some View {
        HStack {
            Button {
                app.sidebarMode = .inbox
            } label: {
                Label("Inbox", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Color.clear.frame(width: 50, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
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
        alert.messageText = "Snooze until"
        alert.accessoryView = picker
        alert.addButton(withTitle: "Snooze")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            app.snooze(threadId, until: picker.dateValue)
        }
    }
}

/// Keeps the sidebar at the top when threads move between sections. When a
/// heading or row appears above the first visible row (a thread going from
/// Running to Needs you, say), the list holds that row where it was, so each
/// change pushed the list further down and hid the headings under the
/// search field (15 pt, then 30 pt, after two turns on one thread). If the
/// list was at the top before the change, it's put back there.
@MainActor
enum SidebarScroll {
    private static weak var cached: NSScrollView?
    private static var scheduled = false

    /// Call before the thread list changes: the list moves itself in the
    /// render pass that follows, so this is the last look at where it was.
    static func threadsWillChange() {
        guard !scheduled, let scroll = scrollView() else { return }
        let top = -scroll.contentInsets.top
        guard scroll.contentView.bounds.minY <= top + 1 else { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            backToTop(scroll, top)
            // In case the list's update landed after this block.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { backToTop(scroll, top) }
        }
    }

    private static func backToTop(_ scroll: NSScrollView, _ top: CGFloat) {
        let clip = scroll.contentView
        guard clip.bounds.minY > top + 1 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    private static func scrollView() -> NSScrollView? {
        if let cached, cached.window != nil { return cached }
        for window in NSApp.windows where window.isVisible {
            if let table = SidebarProbe.table(in: window), let scroll = table.enclosingScrollView {
                cached = scroll
                return scroll
            }
        }
        return nil
    }
}
