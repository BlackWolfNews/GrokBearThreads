import Foundation

/// How a tool row reads when collapsed: an SF Symbol and a one-line title.
public enum ToolPresentation {
    public static func symbol(for kind: ToolKind, name: String) -> String {
        switch kind {
        case .command: return "terminal"
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .write: return "square.and.pencil"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .mcp: return "puzzlepiece.extension"
        case .task: return "person.2"
        case .todo: return "checklist"
        case .other:
            if name.hasPrefix("mcp__") { return "puzzlepiece.extension" }
            return "wrench.and.screwdriver"
        }
    }

    /// The title on one line, home folder shortened to ~, capped in length.
    public static func shortTitle(_ title: String, limit: Int = 160) -> String {
        var line = title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? title
        let home = NSHomeDirectory()
        if line.contains(home) { line = line.replacingOccurrences(of: home, with: "~") }
        if line.count > limit { line = String(line.prefix(limit - 1)) + "…" }
        return line
    }

    /// The tool output preview shown when a tool row is expanded.
    public static func outputPreview(_ tool: ToolItem, maxLines: Int = 400) -> String {
        let text = tool.result?.text ?? tool.liveOutput
        var lines = 0
        var end = text.startIndex
        for index in text.indices where text[index] == "\n" {
            lines += 1
            if lines >= maxLines { end = index; break }
        }
        if lines >= maxLines {
            return String(text[..<end]) + "\n…"
        }
        return text
    }
}
