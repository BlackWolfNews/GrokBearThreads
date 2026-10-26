import Foundation

public enum DiffLineKind: Sendable, Hashable {
    case context, added, removed, hunkHeader, elided
}

public struct DiffDisplayLine: Sendable, Hashable {
    public var kind: DiffLineKind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: DiffLineKind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

/// Builds unified-diff hunks and the lines the diff row shows.
public enum DiffBuilder {
    public static let editToolNames: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    public static func isEditTool(_ call: ToolCall) -> Bool {
        editToolNames.contains(call.name) || call.kind == .edit || call.kind == .write
    }

    /// A diff from an Edit, MultiEdit or Write call's input, for when the
    /// runner didn't send `edit.diff`.
    public static func diff(forTool call: ToolCall) -> EditDiff? {
        guard isEditTool(call) else { return nil }
        let input = call.input
        let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? call.title
        if let oldString = input["old_string"]?.stringValue, let newString = input["new_string"]?.stringValue {
            return EditDiff(itemId: call.itemId, path: path, hunks: hunks(old: oldString, new: newString))
        }
        if let edits = input["edits"]?.arrayValue {
            var all: [DiffHunk] = []
            for edit in edits {
                guard let oldString = edit["old_string"]?.stringValue, let newString = edit["new_string"]?.stringValue else { continue }
                all += hunks(old: oldString, new: newString)
            }
            return EditDiff(itemId: call.itemId, path: path, hunks: all)
        }
        if let content = input["content"]?.stringValue {
            let lines = splitLines(content)
            return EditDiff(itemId: call.itemId, path: path, hunks: lines.isEmpty ? [] : [
                DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines.map { "+" + $0 })
            ])
        }
        return nil
    }

    public static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    public static func hunks(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        hunks(oldLines: splitLines(old), newLines: splitLines(new), context: context)
    }

    /// Unified-diff hunks with `context` lines around each change.
    public static func hunks(oldLines: [String], newLines: [String], context: Int = 3) -> [DiffHunk] {
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return [] }

        // Walk both sides into one edit script of (kind, oldIndex, newIndex).
        struct Step { var mark: Character; var old: Int; var new: Int }
        var script: [Step] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                script.append(Step(mark: "-", old: i, new: j)); i += 1
            } else if j < newLines.count, inserted.contains(j) {
                script.append(Step(mark: "+", old: i, new: j)); j += 1
            } else {
                script.append(Step(mark: " ", old: i, new: j)); i += 1; j += 1
            }
        }

        var result: [DiffHunk] = []
        var position = 0
        while position < script.count {
            guard let changeStart = script[position...].firstIndex(where: { $0.mark != " " }) else { break }
            let start = max(0, changeStart - context)
            var end = changeStart
            // Extend while the next change is within 2 * context lines.
            var cursor = changeStart
            while cursor < script.count {
                if script[cursor].mark != " " {
                    end = cursor
                    cursor += 1
                    continue
                }
                let nextChange = script[cursor...].firstIndex(where: { $0.mark != " " })
                if let nextChange, nextChange - end <= context * 2 {
                    cursor = nextChange
                } else {
                    break
                }
            }
            let stop = min(script.count, end + context + 1)
            var lines: [String] = []
            var oldCount = 0, newCount = 0
            for step in script[start..<stop] {
                switch step.mark {
                case "-": lines.append("-" + oldLines[step.old]); oldCount += 1
                case "+": lines.append("+" + newLines[step.new]); newCount += 1
                default: lines.append(" " + oldLines[step.old]); oldCount += 1; newCount += 1
                }
            }
            let first = script[start]
            result.append(DiffHunk(oldStart: oldCount == 0 ? first.old : first.old + 1, oldLines: oldCount,
                                   newStart: newCount == 0 ? first.new : first.new + 1, newLines: newCount, lines: lines))
            position = stop
        }
        return result
    }

    public static func stats(_ diff: EditDiff) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for hunk in diff.hunks {
            for line in hunk.lines {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    /// Lines for the diff row, numbered, capped at `maxLines` with an
    /// "N more lines" marker at the end.
    public static func displayLines(_ diff: EditDiff, maxLines: Int = .max) -> [DiffDisplayLine] {
        var lines: [DiffDisplayLine] = []
        var total = 0
        for hunk in diff.hunks { total += hunk.lines.count + 1 }
        outer: for (hunkIndex, hunk) in diff.hunks.enumerated() {
            if hunkIndex > 0 || diff.hunks.count > 1 {
                if lines.count >= maxLines { break outer }
                lines.append(DiffDisplayLine(kind: .hunkHeader, text: "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"))
            }
            var oldNumber = hunk.oldStart
            var newNumber = hunk.newStart
            for raw in hunk.lines {
                if lines.count >= maxLines { break outer }
                let mark = raw.first
                let text = raw.isEmpty ? "" : String(raw.dropFirst())
                switch mark {
                case "+":
                    lines.append(DiffDisplayLine(kind: .added, newNumber: newNumber, text: text)); newNumber += 1
                case "-":
                    lines.append(DiffDisplayLine(kind: .removed, oldNumber: oldNumber, text: text)); oldNumber += 1
                default:
                    lines.append(DiffDisplayLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text))
                    oldNumber += 1; newNumber += 1
                }
            }
        }
        let shown = lines.count
        let fullCount = diff.hunks.count > 1 ? total : total - diff.hunks.count
        if shown < fullCount {
            lines.append(DiffDisplayLine(kind: .elided, text: "\(fullCount - shown) more lines"))
        }
        return lines
    }
}
