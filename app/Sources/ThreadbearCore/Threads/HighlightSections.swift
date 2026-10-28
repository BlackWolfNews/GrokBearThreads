import Foundation

/// The Highlights section's groups, top to bottom: pins, files, links and
/// pull requests, commits, then the files the thread edited. Built from
/// what `threads.highlights` answered.
public struct HighlightSections: Sendable, Hashable {
    public var brief: String?
    public var pinned: [Highlight] = []
    public var files: [Highlight] = []
    /// Links and pull requests.
    public var links: [Highlight] = []
    public var commits: [Highlight] = []
    /// Edited files not already listed as a pin or a file.
    public var edited: [String] = []

    /// How many of a long group show before "Show all": a long thread can
    /// have fifteen commits, which pushed Files and Links off screen.
    public static let commitLimit = 5
    public static let linkLimit = 10

    /// The first `limit` of a group (they come newest first), and how many
    /// more "Show all" would add. All of them once Mike has asked.
    public static func capped<T>(_ items: [T], limit: Int, showAll: Bool) -> (shown: [T], more: Int) {
        guard !showAll, items.count > limit else { return (items, 0) }
        return (Array(items.prefix(limit)), items.count - limit)
    }

    /// Nothing to show but the empty line.
    public var isEmpty: Bool {
        brief == nil && pinned.isEmpty && files.isEmpty && links.isEmpty && commits.isEmpty && edited.isEmpty
    }

    public static func build(_ highlights: ThreadHighlights) -> HighlightSections {
        var sections = HighlightSections()
        let brief = highlights.brief?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sections.brief = brief.isEmpty ? nil : brief
        for item in highlights.highlights {
            if item.isPinned {
                sections.pinned.append(item)
                continue
            }
            switch item.kind {
            case .file: sections.files.append(item)
            case .link, .pr: sections.links.append(item)
            case .commit: sections.commits.append(item)
            case .other:
                // A kind from a newer runner: as a file or a link if it's
                // one, else nothing this app knows how to open.
                if item.path != nil { sections.files.append(item) } else if item.url != nil { sections.links.append(item) }
            }
        }
        let listed = Set((sections.pinned + sections.files).compactMap(\.path))
        var seen = Set<String>()
        sections.edited = highlights.edited.filter { !listed.contains($0) && seen.insert($0).inserted }
        return sections
    }
}

/// Where a click on a highlight, a list panel's row or a transcript link
/// opens it: in the pane beside the transcript, or out in the default app.
public enum PreviewRules {
    public enum Place: Equatable, Sendable {
        /// The pane's preview: a file.
        case pane
        /// The default browser: any web page, localhost too. Mike wants
        /// links in Chrome, never in the app (28 Oct); "Preview here" in a
        /// link's menu still puts one in the pane when he asks.
        case browser
    }

    public enum Viewer: Equatable, Sendable {
        /// A web view: a page, or an `.html` file with what it links to.
        case web
        /// Quick Look: images, PDFs, video, Markdown, text, CSV and the rest.
        case quickLook
    }

    public static func place(for url: URL) -> Place {
        url.isFileURL ? .pane : .browser
    }

    public static func viewer(forPath path: String) -> Viewer {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm" ? .web : .quickLook
    }

    /// The kinds of file Mike reviews rather than edits: a transcript link
    /// to one of these opens in the pane, not in its app (⌘-click still
    /// does that).
    public static let reviewExtensions: Set<String> = [
        "md", "html", "htm", "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "csv", "txt",
    ]

    public static func previewsInPane(transcriptLink url: URL) -> Bool {
        url.isFileURL && reviewExtensions.contains(url.pathExtension.lowercased())
    }
}

/// An SF Symbol for a file, by its extension.
public enum FileIcon {
    public static func symbol(forPath path: String) -> String {
        if path.hasSuffix("/") { return "folder" }
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "html", "htm": return "safari"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff": return "photo"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "wav", "m4a", "aiff": return "waveform"
        case "csv", "tsv", "xlsx", "numbers": return "tablecells"
        case "json", "yaml", "yml", "toml", "plist": return "curlybraces.square"
        case "zip", "gz", "tar", "dmg": return "archivebox"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// A highlight's: a file's by its extension, the rest by kind.
    public static func symbol(for highlight: Highlight) -> String {
        switch highlight.kind {
        case .pr: return "arrow.triangle.pull"
        case .commit: return "smallcircle.filled.circle"
        case .link: return "link"
        case .file: return symbol(forPath: highlight.path ?? highlight.title)
        case .other: return highlight.path.map(symbol(forPath:)) ?? "link"
        }
    }
}

/// Short words for a highlight row.
public enum HighlightText {
    /// The folder a file is in, as a row's second line: inside the
    /// thread's folder, relative to it ("docs/mockups"), or the folder's
    /// own name for a file at its top; elsewhere the full path with `~`.
    public static func folder(of path: String, cwd: String?, home: String = NSHomeDirectory()) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if let cwd, !cwd.isEmpty {
            let root = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            if parent == root { return (root as NSString).lastPathComponent }
            if parent.hasPrefix(root + "/") { return String(parent.dropFirst(root.count + 1)) }
        }
        if !home.isEmpty, parent == home || parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }

    /// A link's second line: its host and path, without the scheme.
    public static func address(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// "pushed" or "not pushed yet", after the branch.
    public static func commitLine(_ commit: Highlight) -> String {
        let state = commit.pushed ? "pushed" : "not pushed yet"
        guard let branch = commit.branch, !branch.isEmpty else { return state }
        return "\(branch) · \(state)"
    }

    public static func editedCount(_ count: Int) -> String {
        count == 1 ? "1 file edited" : "\(count) files edited"
    }
}

/// Decides when a fetch should open a pin in the pane by itself: a pin the
/// agent asked to have shown (`show`) that wasn't there, shown, last time.
/// Never on a thread's first fetch this session, so opening an old thread
/// doesn't throw its old mockups at Mike.
public struct HighlightAutoShow: Sendable {
    /// Per thread, the ids that had `show` in the last fetch. An item that
    /// goes away (unpinned) leaves it, so pinning it again shows it again.
    private var shown: [String: Set<String>] = [:]

    public init() {}

    public mutating func receive(_ highlights: ThreadHighlights, threadId: String) -> Highlight? {
        let showing = highlights.highlights.filter(\.show)
        let previous = shown[threadId]
        shown[threadId] = Set(showing.map(\.id))
        guard let previous else { return nil }
        return showing.filter { !previous.contains($0.id) }.max { max($0.seq, $0.lastSeq) < max($1.seq, $1.lastSeq) }
    }

    /// Forgets a thread (it was deleted), so a thread with the same id
    /// later counts as new.
    public mutating func forget(_ threadId: String) { shown[threadId] = nil }
}

/// The SF Symbol for a panel's button on the rail: its own, else one for
/// the built-in panels, else one by kind.
public enum PanelIcon {
    public static func symbol(for panel: Panel) -> String {
        if let icon = panel.icon, !icon.isEmpty { return icon }
        switch panel.id {
        case "convex.dashboard": return "cylinder.split.1x2"
        case "xcode.simulator": return "iphone"
        default: break
        }
        switch panel.kind {
        case .url: return "globe"
        case .image: return "photo"
        case .list: return "list.bullet"
        }
    }
}
