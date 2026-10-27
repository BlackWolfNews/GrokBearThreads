import Foundation

/// A project's part of the sidebar's Projects view: its header, and its
/// threads under it.
public struct ProjectSection: Sendable, Equatable, Identifiable {
    public var project: Project
    /// Its threads in the inbox (not put away), newest activity first.
    public var threads: [ThreadSummary]
    /// Its newest thread's activity (put away ones too), else the runner's.
    public var lastActivityAt: Date

    public var id: String { project.id }
}

/// The Projects view: a section per project, newest activity first, then
/// the threads in no project.
public struct ProjectSections: Sendable, Equatable {
    public var sections: [ProjectSection] = []
    /// Inbox threads in no project the view shows (none, or only archived
    /// or unknown ones), newest first.
    public var unfiled: [ThreadSummary] = []

    public init(sections: [ProjectSection] = [], unfiled: [ThreadSummary] = []) {
        self.sections = sections
        self.unfiled = unfiled
    }

    /// Archived projects are left out, and so are archived and hibernating
    /// threads, as in the inbox. A thread in two projects is under both.
    public static func build(projects: [Project], threads: some Sequence<ThreadSummary>, now: Date) -> ProjectSections {
        let shown = projects.filter { !$0.archived }
        let shownIds = Set(shown.map(\.id))
        var members: [String: [ThreadSummary]] = [:]
        var newest: [String: Date] = [:]
        var unfiled: [ThreadSummary] = []
        for thread in threads {
            let inbox = !thread.isArchived && !thread.isSnoozed(at: now)
            var filed = false
            for membership in thread.projects where shownIds.contains(membership.id) {
                filed = true
                newest[membership.id] = max(newest[membership.id] ?? .distantPast, thread.lastActivityAt)
                if inbox { members[membership.id, default: []].append(thread) }
            }
            if inbox && !filed { unfiled.append(thread) }
        }
        let newestFirst: (ThreadSummary, ThreadSummary) -> Bool = {
            $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id
        }
        var sections = shown.map { project in
            ProjectSection(
                project: project,
                threads: (members[project.id] ?? []).sorted(by: newestFirst),
                lastActivityAt: max(newest[project.id] ?? .distantPast, project.lastActivityAt ?? project.updatedAt)
            )
        }
        sections.sort {
            $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt
                : $0.project.title.localizedStandardCompare($1.project.title) == .orderedAscending
        }
        return ProjectSections(sections: sections, unfiled: unfiled.sorted(by: newestFirst))
    }

    /// Thread ids top to bottom, for the arrow keys. A thread in two
    /// projects is in it twice; the first is where the arrows land.
    public var order: [String] {
        var seen = Set<String>()
        return (sections.flatMap(\.threads) + unfiled).map(\.id).filter { seen.insert($0).inserted }
    }

    /// A project's threads (any, put away ones too), newest activity first,
    /// for its page.
    public static func threads(in projectId: String, from threads: some Sequence<ThreadSummary>) -> [ThreadSummary] {
        threads
            .filter { $0.projects.contains { $0.id == projectId } }
            .sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id }
    }
}

/// The Patches tab's groups: the patches from the thread's own folder (and
/// home and the built-ins) first, then each project's, so it's clear why a
/// chip or panel is there.
public struct PatchGroup: Sendable, Equatable, Identifiable {
    /// Nil for the thread's own folder.
    public var projectId: String?
    /// The project's title; nil for the thread's own folder.
    public var title: String?
    public var patches: [PatchInfo]

    public var id: String { projectId ?? "" }
}

public enum PatchGroups {
    /// One group with no title when nothing came from a project, as the
    /// tab was before projects.
    public static func group(_ thread: ThreadSummary, projectTitle: (String) -> String? = { _ in nil }) -> [PatchGroup] {
        let own = thread.patches.filter { $0.projectId == nil }
        let fromProjects = thread.patches.filter { $0.projectId != nil }
        guard !fromProjects.isEmpty else { return own.isEmpty ? [] : [PatchGroup(projectId: nil, title: nil, patches: own)] }
        var groups: [PatchGroup] = []
        if !own.isEmpty { groups.append(PatchGroup(projectId: nil, title: nil, patches: own)) }
        // The thread's projects in its order, then any it isn't in any more
        // (a summary a moment behind).
        var ids = thread.projects.map(\.id)
        for patch in fromProjects where !ids.contains(patch.projectId!) { ids.append(patch.projectId!) }
        for id in ids {
            let patches = fromProjects.filter { $0.projectId == id }
            guard !patches.isEmpty else { continue }
            let title = thread.projects.first { $0.id == id }?.title ?? projectTitle(id) ?? "A project"
            groups.append(PatchGroup(projectId: id, title: title, patches: patches))
        }
        return groups
    }

    /// A project's patches across its threads, each once (by id and
    /// folder), for its page: what the project gives a thread put in it.
    public static func patches(of projectId: String, in threads: [ThreadSummary]) -> [(patch: PatchInfo, thread: ThreadSummary)] {
        var seen = Set<String>()
        var out: [(PatchInfo, ThreadSummary)] = []
        for thread in threads {
            for patch in thread.patches where patch.projectId == projectId {
                if seen.insert(patch.id + "|" + (patch.folder ?? "")).inserted { out.append((patch, thread)) }
            }
        }
        return out
    }
}

/// The words the Librarian view uses.
public enum LibrarianText {
    /// "Idle", "Looking at Rename the Settings tabs", "Paused", "Off: No
    /// OpenRouter key".
    public static func state(_ status: LibrarianStatus) -> String {
        switch status.state {
        case .idle: return status.paused ? "Paused" : "Idle"
        case .working:
            guard let current = status.current else { return "Working" }
            let title = current.threadTitle.isEmpty ? "a thread" : "\u{201C}\(current.threadTitle)\u{201D}"
            return "Looking at \(title)"
        case .paused: return "Paused"
        case .off:
            guard let reason = status.reason, !reason.isEmpty else { return "Off" }
            return "Off: \(reason)"
        }
    }

    /// The reason a look is queued, when the runner gave no words for it.
    public static func reason(_ reason: LibrarianReason) -> String {
        switch reason {
        case .firstTurn: return "Its first turn ended"
        case .newFolder: return "Edited files in a new folder"
        case .moved: return "Moved to another folder"
        case .catchUp: return "More turns since the last look"
        case .asked: return "Asked for"
        }
    }

    public static func why(_ job: LibrarianJob) -> String {
        job.why.isEmpty ? reason(job.reason) : job.why
    }

    /// "14 looks today · $0.03".
    public static func today(_ status: LibrarianStatus) -> String {
        let looks = status.looksToday == 1 ? "1 look today" : "\(status.looksToday) looks today"
        let spend = CostText.format(status.spentTodayUsd) ?? "$0"
        return "\(looks) · \(spend)"
    }

    /// "in 4m", "now", or "waiting" for one more than a minute overdue:
    /// looks wait while it's paused, off or busy with another.
    public static func due(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        if date.timeIntervalSince(now) > -60 { return ScheduleTime.relative(date, now: now) }
        return "waiting"
    }
}
