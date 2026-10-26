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

    /// The title for a tool that's running now, for a live group's line: a
    /// bare command reads "Running npm test"; a described one keeps its
    /// description ("Run the upload tests").
    public static func activeTitle(_ tool: ToolItem) -> String {
        let title = shortTitle(tool.title, limit: 80)
        if tool.toolKind == .command, let command = tool.call?.input["command"]?.stringValue,
           shortTitle(command, limit: 80) == title {
            return "Running " + title
        }
        return title
    }

    /// What an expanded tool row shows, by kind of tool. The view lays each
    /// one out as content (a command and its output, a file with line
    /// numbers) rather than the raw input object.
    public enum Detail: Sendable, Hashable {
        case command(command: String, output: String)
        case file(path: String, lines: [NumberedLine])
        case search(query: String, scope: String?, output: String)
        case fields(fields: [Field], output: String)
    }

    public struct Field: Sendable, Hashable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public struct NumberedLine: Sendable, Hashable {
        public var number: Int?
        public var text: String

        public init(number: Int?, text: String) {
            self.number = number
            self.text = text
        }
    }

    public static func detail(_ tool: ToolItem, maxLines: Int = 400) -> Detail {
        let output = outputPreview(tool, maxLines: maxLines).trimmingCharacters(in: .newlines)
        let input = tool.call?.input ?? .object([:])
        switch tool.toolKind {
        case .command:
            if let command = input["command"]?.stringValue {
                return .command(command: command, output: output)
            }
        case .read:
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue, tool.result.map({ $0.ok }) ?? true {
                let offset = input["offset"]?.doubleValue.map { max(1, Int($0)) } ?? 1
                return .file(path: shortTitle(path, limit: 400), lines: numberedLines(output, from: offset))
            }
        case .search:
            if let query = input["pattern"]?.stringValue ?? input["query"]?.stringValue {
                let scope = (input["path"]?.stringValue ?? input["glob"]?.stringValue).map { shortTitle($0, limit: 200) }
                return .search(query: query, scope: scope, output: output)
            }
        default:
            break
        }
        return .fields(fields: fields(input), output: output)
    }

    /// The input as `key: value` lines: strings as they are, other values as
    /// compact JSON, long values cut to a few lines.
    public static func fields(_ input: JSONValue) -> [Field] {
        guard let object = input.objectValue else {
            let text = input.compactText
            return text.isEmpty || text == "null" ? [] : [Field(key: "input", value: text)]
        }
        return object.keys.sorted().compactMap { key in
            guard let value = object[key] else { return nil }
            var text: String
            switch value {
            case .string(let string): text = string
            case .null: return nil
            default: text = value.compactText
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 6 { text = lines.prefix(6).joined(separator: "\n") + "\n…" }
            if text.count > 600 { text = String(text.prefix(599)) + "…" }
            return Field(key: key, value: text)
        }
    }

    /// File content with line numbers. Claude's Read results already number
    /// their lines ("    12→text" or "12<tab>text"); those numbers are used.
    /// Otherwise lines are numbered from `start`.
    public static func numberedLines(_ text: String, from start: Int = 1) -> [NumberedLine] {
        guard !text.isEmpty else { return [] }
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        var parsed: [NumberedLine] = []
        parsed.reserveCapacity(raw.count)
        var allNumbered = true
        for line in raw {
            if let numbered = parseNumbered(line) {
                parsed.append(numbered)
            } else if line.hasPrefix("…") || line.isEmpty {
                parsed.append(NumberedLine(number: nil, text: String(line)))
            } else {
                allNumbered = false
                break
            }
        }
        if allNumbered, parsed.contains(where: { $0.number != nil }) { return parsed }
        return raw.enumerated().map { index, line in
            line == "…" ? NumberedLine(number: nil, text: "…") : NumberedLine(number: start + index, text: String(line))
        }
    }

    static func parseNumbered(_ line: Substring) -> NumberedLine? {
        let trimmed = line.drop(while: { $0 == " " })
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 7, let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "→" || separator == "\t" else { return nil }
        return NumberedLine(number: number, text: String(rest.dropFirst()))
    }
}
