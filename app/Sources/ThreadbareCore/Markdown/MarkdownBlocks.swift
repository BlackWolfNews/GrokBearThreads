import Foundation

/// Splits markdown into top-level blocks so each one can be rendered and
/// cached on its own. While a message streams, every block but the last is
/// finished, so only the last one is re-rendered on each update.
///
/// Rules: a blank line outside a fenced code block ends a block; a fenced
/// code block is one block even with blank lines inside; list items and
/// indented continuation lines after a blank line stay with their list so
/// numbering and nesting survive.
public enum MarkdownBlocks {
    public static func split(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var pendingBlank = 0
        var fence: (marker: Character, length: Int)?
        var currentIsList = false
        var fenceInList = false

        func flush() {
            if !current.isEmpty {
                blocks.append(current.joined(separator: "\n"))
            }
            current = []
            pendingBlank = 0
            currentIsList = false
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                current.append(line)
                if isFenceClose(line, marker: open.marker, length: open.length) {
                    fence = nil
                    if !fenceInList { flush() }
                }
                continue
            }
            if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                if !current.isEmpty { pendingBlank += 1 }
                continue
            }
            if let opening = fenceOpen(line) {
                // A fence starts its own block, even straight after a paragraph.
                fenceInList = currentIsList && isIndented(line)
                if !fenceInList {
                    flush()
                } else if pendingBlank > 0 {
                    current.append(contentsOf: Array(repeating: "", count: pendingBlank))
                    pendingBlank = 0
                }
                current.append(line)
                fence = opening
                continue
            }
            if pendingBlank > 0 {
                let continuesList = currentIsList && (isListItem(line) || isIndented(line))
                if continuesList {
                    current.append(contentsOf: Array(repeating: "", count: pendingBlank))
                    pendingBlank = 0
                } else {
                    flush()
                }
            }
            if current.isEmpty { currentIsList = isListItem(line) }
            current.append(line)
        }
        flush()
        return blocks
    }

    static func isIndented(_ line: Substring) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    static func isListItem(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return trimmed.dropFirst().first == " "
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
    }

    static func fenceOpen(_ line: Substring) -> (marker: Character, length: Int)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let trimmed = line.dropFirst(indent)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        if marker == "`" && trimmed.dropFirst(length).contains("`") { return nil }
        return (marker, length)
    }

    static func isFenceClose(_ line: Substring, marker: Character, length: Int) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let trimmed = line.dropFirst(indent)
        let run = trimmed.prefix(while: { $0 == marker }).count
        guard run >= length else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }
}
