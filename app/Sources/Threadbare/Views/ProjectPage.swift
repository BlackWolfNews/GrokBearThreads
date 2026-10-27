import AppKit
import SwiftUI
import ThreadbareCore

/// A project's page, in the detail area in place of a thread: its title,
/// goals, state and notes (each editable), its folders, its threads and the
/// patches its folders give them. Archive, merge and delete are in the
/// toolbar's ... menu.
struct ProjectPage: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        let threads = ProjectSections.threads(in: project.id, from: app.threads.values)
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(30)) {
                HStack(alignment: .center, spacing: zoomed(14)) {
                    IconButton(project: project)
                    VStack(alignment: .leading, spacing: zoomed(6)) {
                        TitleField(project: project)
                        Text(ProjectPage.madeBy(project, threads: threads.count, app: app))
                            .font(.system(size: TypeScale.label))
                            .foregroundStyle(Color(nsColor: Theme.faintText))
                    }
                }
                TextSection(project: project, field: .goals)
                TextSection(project: project, field: .state)
                TextSection(project: project, field: .notes)
                FoldersSection(project: project)
                ThreadsSection(project: project, threads: threads)
                PatchesSection(project: project, threads: threads)
            }
            .frame(maxWidth: zoomed(720), alignment: .leading)
            .padding(.horizontal, zoomed(32))
            .padding(.top, zoomed(28))
            .padding(.bottom, zoomed(48))
            .frame(maxWidth: .infinity)
        }
        .id(project.id)
    }

    /// "Made by the librarian on 20 Oct · 5 threads".
    static func madeBy(_ project: Project, threads: Int, app: AppModel) -> String {
        let who: String
        switch project.createdBy {
        case .mike: who = "Made by you"
        case .agent: who = "Made by an agent"
        case .librarian: who = "Made by the librarian"
        }
        var parts = [who + " on " + project.createdAt.formatted(.dateTime.day().month(.abbreviated))]
        let count = max(threads, project.threadCount)
        parts.append(count == 1 ? "1 thread" : "\(count) threads")
        if project.archived { parts.append("Archived") }
        return parts.joined(separator: " · ")
    }
}

/// The project's icon, big, with a menu to choose another or go back to
/// the one the librarian finds. The tooltip says where it came from.
private struct IconButton: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Choose a Picture…") { app.chooseProjectIcon(project.id) }
            if project.icon?.isChosen == true {
                Button("Use the Librarian's Icon") { app.setProjectIconAutomatic(project.id) }
            }
            if let from = project.icon?.from {
                Divider()
                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: from)]) }
            }
        } label: {
            ProjectIconView(project: project, size: 44)
                .opacity(hovering ? 0.8 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(Self.help(project))
    }

    static func help(_ project: Project) -> String {
        guard let icon = project.icon else { return "No icon yet: the librarian looks in the project's folders for one. Click to choose a picture." }
        let source = icon.from.map { "from \($0.abbreviatingHome)" } ?? icon.symbol.map { "the \($0) symbol" } ?? ""
        switch icon.by {
        case .librarian: return "The librarian found this (\(source)) and keeps it up to date. Click to choose another."
        case .mike: return "You chose this (\(source)). Click to change it."
        case .agent: return "An agent chose this (\(source)). Click to change it."
        }
    }
}

/// The title, edited in place; Return saves it, Esc puts it back.
private struct TitleField: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: zoomed(24), weight: .semibold))
            .focused($focused)
            .onAppear { draft = project.title }
            .onChange(of: project.title) { _, title in if !focused { draft = title } }
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onExitCommand {
                draft = project.title
                focused = false
            }
            .help("The project's name")
    }

    private func save() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { draft = project.title; return }
        if title != project.title { app.updateProject(project.id, ProjectUpdate(title: title)) }
    }
}

/// A section's heading, with anything that acts on the section at its right.
private struct PageHeading<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
            Text(title)
                .font(.system(size: TypeScale.label, weight: .semibold))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: TypeScale.small))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
            }
            Spacer(minLength: zoomed(8))
            trailing()
        }
        .padding(.bottom, zoomed(6))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
        .padding(.bottom, zoomed(8))
    }
}

extension PageHeading where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Goals, state or notes: the text, and Edit to change it in a box with
/// Save and Cancel. Not saved as it's typed, so the librarian's or an
/// agent's update arriving meanwhile doesn't fight the typing.
private struct TextSection: View {
    enum Field {
        case goals, state, notes

        var title: String {
            switch self {
            case .goals: return "Goals"
            case .state: return "State"
            case .notes: return "Notes"
            }
        }

        var empty: String {
            switch self {
            case .goals: return "What it's for and what done looks like."
            case .state: return "Where it's up to, what's next and what's blocked."
            case .notes: return "Decisions, gotchas, commands and links worth keeping."
            }
        }
    }

    @Environment(AppModel.self) private var app
    let project: Project
    let field: Field
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false

    private var text: String {
        switch field {
        case .goals: return project.goals
        case .state: return project.state
        case .notes: return project.notes
        }
    }

    private var detail: String? {
        guard field == .state, let at = project.stateUpdatedAt else { return nil }
        let ago = RelativeTime.short(at, now: app.now)
        return "updated " + (ago == "now" ? "just now" : ago + " ago")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: field.title, detail: detail) {
                if !editing {
                    Button("Edit") { start() }
                        .buttonStyle(.borderless)
                        .font(.system(size: TypeScale.detail))
                        .opacity(hovering ? 1 : 0.6)
                }
            }
            if editing {
                VStack(alignment: .trailing, spacing: zoomed(8)) {
                    TextEditor(text: $draft)
                        .font(.system(size: TypeScale.label))
                        .scrollContentBackground(.hidden)
                        .padding(zoomed(6))
                        .frame(minHeight: zoomed(field == .notes ? 220 : 90))
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: zoomed(6)))
                        .overlay(RoundedRectangle(cornerRadius: zoomed(6)).strokeBorder(.separator, lineWidth: 0.5))
                    HStack(spacing: zoomed(8)) {
                        Button("Cancel") { editing = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Save") { save() }
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    .controlSize(.small)
                }
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(field.empty)
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
                    .onTapGesture(count: 2) { start() }
            } else {
                Text(TextSection.markdown(text))
                    .font(.system(size: TypeScale.label))
                    .lineSpacing(zoomed(3))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onHover { hovering = $0 }
    }

    private func start() {
        draft = text
        editing = true
    }

    private func save() {
        editing = false
        guard draft != text else { return }
        switch field {
        case .goals: app.updateProject(project.id, ProjectUpdate(goals: draft))
        case .state: app.updateProject(project.id, ProjectUpdate(state: draft))
        case .notes: app.updateProject(project.id, ProjectUpdate(notes: draft))
        }
    }

    /// Bold, code and links, with the line breaks kept. Headings and lists
    /// show as their plain lines, which reads well enough for notes.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Its folders: patches load from each of them. A folder shows in Finder;
/// the minus takes it out.
private struct FoldersSection: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(2)) {
            PageHeading(title: "Folders") {
                Button("Add folder…") { app.addProjectFolder(project.id) }
                    .buttonStyle(.borderless)
                    .font(.system(size: TypeScale.detail))
            }
            ForEach(project.folders, id: \.self) { folder in
                FolderRow(project: project, folder: folder)
            }
            if project.folders.isEmpty {
                Text("None yet. A thread in the project gets the patches in each of its folders.")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
            }
        }
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var app
    let project: Project
    let folder: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: zoomed(8)) {
            Image(systemName: "folder")
                .font(.system(size: zoomed(12)))
                .foregroundStyle(.secondary)
                .frame(width: zoomed(16))
            PlainLink(title: folder.abbreviatingHome, help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            }
            .font(.system(size: TypeScale.label))
            Spacer(minLength: zoomed(8))
            Button { app.removeProjectFolder(project.id, folder) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(RowIconButtonStyle())
                .help("Take this folder out of the project")
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, zoomed(3))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Its threads, put away ones too, newest first. A row opens its thread.
private struct ThreadsSection: View {
    @Environment(AppModel.self) private var app
    let project: Project
    let threads: [ThreadSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: "Threads", detail: threads.isEmpty ? nil : "\(threads.count)")
            ForEach(threads) { thread in
                ProjectThreadRow(project: project, thread: thread)
            }
            if threads.isEmpty {
                Text("No threads in it yet. The librarian puts threads here as they work in its folders, or add one from a thread's ... menu.")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
            }
        }
    }
}

private struct ProjectThreadRow: View {
    @Environment(AppModel.self) private var app
    let project: Project
    let thread: ThreadSummary
    @State private var hovering = false

    private var membership: ThreadProject? { thread.projects.first { $0.id == project.id } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(thread.isArchived ? .secondary : .primary)
                .lineLimit(1)
            Text(FolderName.short(thread.cwd))
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(Color(nsColor: Theme.faintText))
                .lineLimit(1)
            Spacer(minLength: zoomed(8))
            Text(meta)
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(Color(nsColor: Theme.faintText))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, zoomed(8))
        .padding(.vertical, zoomed(6))
        .background(hovering ? SidebarMetrics.hover : .clear, in: RoundedRectangle(cornerRadius: zoomed(6)))
        .padding(.horizontal, -zoomed(8))
        .contentShape(Rectangle())
        .onTapGesture { app.openThread(thread.id) }
        .onHover { hovering = $0 }
        .help(by)
        .contextMenu {
            Button("Open") { app.openThread(thread.id) }
            if membership?.pinned == false {
                Button("Keep it in \(project.title)") { app.setProjects(thread.id, add: [project.id]) }
            }
            Button("Take it out of \(project.title)") { app.setProjects(thread.id, remove: [project.id]) }
        }
    }

    /// "Archived · 3d", or just when it was last active.
    private var meta: String {
        let when = RelativeTime.short(thread.lastActivityAt, now: app.now)
        if thread.isArchived { return "Archived · " + when }
        if thread.isSnoozed(at: app.now) { return "Hibernating · " + when }
        return when
    }

    /// Who put it here, for the tooltip.
    private var by: String {
        guard let membership else { return "" }
        switch membership.by {
        case .mike: return "You put it here"
        case .agent: return membership.pinned ? "Its agent put it here" : "An agent put it here"
        case .librarian: return membership.pinned ? "The librarian put it here and you kept it" : "The librarian put it here"
        }
    }
}

/// What the project's folders give its threads, as their summaries say,
/// and where each came from. Each patch once, however many threads have it.
private struct PatchesSection: View {
    @Environment(AppModel.self) private var app
    let project: Project
    let threads: [ThreadSummary]

    var body: some View {
        let found = PatchGroups.patches(of: project.id, in: threads)
        VStack(alignment: .leading, spacing: zoomed(12)) {
            PageHeading(title: "Patches", detail: found.isEmpty ? nil : "\(found.count)")
            ForEach(found, id: \.patch.id) { item in
                VStack(alignment: .leading, spacing: zoomed(3)) {
                    HStack(spacing: zoomed(6)) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: zoomed(11), weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(item.patch.id)
                            .font(.system(size: TypeScale.label, weight: .medium))
                        Text(PatchesList.sourceName(item.patch.source))
                            .font(.system(size: TypeScale.small))
                            .foregroundStyle(Color(nsColor: Theme.faintText))
                    }
                    if let error = item.patch.error {
                        Text(error)
                            .font(.system(size: TypeScale.detail))
                            .foregroundStyle(Color(nsColor: Theme.failed))
                            .textSelection(.enabled)
                    } else {
                        let gives = PatchesList.gives(item.patch.id, in: item.thread)
                        if !gives.isEmpty {
                            Text(gives)
                                .font(.system(size: TypeScale.detail))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let from = item.patch.file ?? item.patch.folder {
                        PlainLink(title: from.abbreviatingHome, help: item.patch.file == nil ? "Show the folder in Finder" : "Open the file") {
                            if let file = item.patch.file {
                                NSWorkspace.shared.open(URL(fileURLWithPath: file))
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: from)])
                            }
                        }
                        .font(.system(size: TypeScale.small))
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                    }
                }
            }
            if found.isEmpty {
                Text("None from its folders yet. A patch in .threadbear/patches in one of them shows here, and on every thread in the project.")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
            }
        }
    }
}
