import AppKit
import SwiftUI
import ThreadbareCore

/// The sidebar's Projects view: a section per project, newest activity
/// first, with its open threads under it (a thread in two projects is
/// under both), then the threads in no project. A project's header opens
/// its page.
struct ProjectsList: View {
    @Environment(AppModel.self) private var app
    @State private var showArchived = false

    var body: some View {
        let built = app.projectSections
        let archived = app.projects.filter(\.archived)
        // Each thread's first row, for the arrow keys to scroll to.
        var firstRow: [String: String] = [:]
        for section in built.sections {
            for thread in section.threads where firstRow[thread.id] == nil {
                firstRow[thread.id] = SectionRow.id(section: section.id, thread: thread.id)
            }
        }
        for thread in built.unfiled where firstRow[thread.id] == nil {
            firstRow[thread.id] = SectionRow.id(section: Self.unfiledId, thread: thread.id)
        }
        return VStack(spacing: 0) {
            ModeHeader(title: "Projects", count: built.sections.count)
            SidebarButtonRow(icon: "plus", title: "New project") {
                app.newProject(with: nil)
            }
            .padding(.horizontal, SidebarMetrics.outerInset)
            ThreadList(order: built.order, scrollID: { firstRow[$0] ?? $0 }) { select in
                if app.threadsLoaded {
                    ForEach(built.sections) { section in
                        ProjectHeader(project: section.project, count: section.threads.count)
                        ForEach(section.threads.map { SectionRow(section: section.id, thread: $0) }) { row in
                            ThreadRowView(thread: row.thread, mode: .projects) { select(row.thread.id) }
                        }
                    }
                    if !built.unfiled.isEmpty {
                        SectionHeading(title: "Not in a project")
                        ForEach(built.unfiled.map { SectionRow(section: Self.unfiledId, thread: $0) }) { row in
                            ThreadRowView(thread: row.thread, mode: .projects) { select(row.thread.id) }
                        }
                    }
                    if built.sections.isEmpty && built.unfiled.isEmpty {
                        EmptyNote(text: "No projects yet.")
                    }
                    if !archived.isEmpty {
                        ArchivedProjects(projects: archived, shown: $showArchived)
                    }
                }
            }
        }
    }

    static let unfiledId = "-"
}

/// A project's heading: its title, quiet like the inbox's headings but a
/// button, highlighted while its page is open.
private struct ProjectHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    let project: Project
    /// Its open threads, listed under it.
    let count: Int
    @State private var hovering = false

    private var isOpen: Bool { app.openProjectId == project.id }

    var body: some View {
        Button { app.openProjectPage(project.id) } label: {
            HStack(spacing: zoomed(6)) {
                Text(project.title)
                    .font(.system(size: TypeScale.sidebarHeading, weight: .semibold))
                    .foregroundStyle(isOpen || hovering ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: zoomed(6))
                if hovering {
                    Image(systemName: "chevron.right")
                        .font(.system(size: zoomed(10), weight: .semibold))
                        .foregroundStyle(SidebarMetrics.faint)
                } else if count > 0 {
                    Text("\(count)")
                        .font(.system(size: TypeScale.sidebarMeta))
                        .foregroundStyle(SidebarMetrics.faint)
                        .monospacedDigit()
                }
            }
            .padding(.leading, SidebarMetrics.leading)
            .padding(.trailing, SidebarMetrics.trailing)
            .padding(.vertical, zoomed(6))
            .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // The same room above each group as the inbox's headings.
        .padding(.top, zoomed(12))
        .padding(.bottom, zoomed(2))
        .help("Open \(project.title)")
        .contextMenu { ProjectMenu(project: project) }
        .accessibilityAddTraits(.isHeader)
    }

    private var background: Color {
        if isOpen { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return hovering ? SidebarMetrics.hover : .clear
    }
}

/// Archived projects, folded away at the foot; each opens its page.
private struct ArchivedProjects: View {
    @Environment(AppModel.self) private var app
    let projects: [Project]
    @Binding var shown: Bool

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: zoomed(5)) {
                Text("Archived projects")
                Image(systemName: shown ? "chevron.down" : "chevron.right")
                    .font(.system(size: zoomed(9), weight: .semibold))
                Spacer(minLength: 0)
                Text("\(projects.count)").monospacedDigit()
            }
            .font(.system(size: TypeScale.sidebarHeading, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.leading)
            .padding(.trailing, SidebarMetrics.trailing)
            .padding(.top, zoomed(18))
            .padding(.bottom, zoomed(6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if shown {
            ForEach(projects) { project in
                SidebarButtonRow(icon: "archivebox", title: project.title, active: app.openProjectId == project.id) {
                    app.openProjectPage(project.id)
                }
            }
        }
    }
}

/// Archive, merge and delete: the project header's context menu and the
/// toolbar's ... menu while its page is open.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        if app.openProjectId != project.id {
            Button("Open") { app.openProjectPage(project.id) }
            Divider()
        }
        if project.archived {
            Button("Unarchive") { app.setProjectArchived(project.id, false) }
        } else {
            Button("Archive") { app.setProjectArchived(project.id, true) }
        }
        let others = app.projects.filter { $0.id != project.id && !$0.archived }
        if !others.isEmpty {
            Menu("Merge into") {
                ForEach(others) { other in
                    Button(other.title) { app.mergeProject(project.id, into: other.id) }
                }
            }
        }
        Divider()
        Button("Copy project id") { app.copyToPasteboard(project.id) }
        Divider()
        Button("Delete…") { app.deleteProject(project.id) }
    }
}
