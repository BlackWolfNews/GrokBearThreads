import Foundation

/// Assistant text split into the blocks the phone draws: paragraphs,
/// headings, list items (with their depth), code, quotes, rules, tables and
/// pictures.
/// The Mac renders the same text with react-markdown and remark-gfm, so this
/// follows GitHub's rules for what agents actually write; the phone's own
/// first parser knew only paragraphs, headings, flat bullets and code, and
/// showed tables and quotes as raw pipes and arrows (Mike, 31 Oct).
/// Inline markdown (bold, code, links) is left in the text for the view's
/// AttributedString pass.
public indirect enum MarkdownBlock: Sendable, Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is "•" or "3."; `task` is nil, or whether its box is ticked.
    case listItem(text: String, marker: String, depth: Int, task: Bool?)
    case code(String)
    /// A ```mermaid or ```html block, drawn as the diagram or page it
    /// describes, with a switch back to its source (RichBlockView).
    case rich(kind: RichKind, source: String)
    case quote([MarkdownBlock])
    case rule
    case table(header: [String], alignments: [Alignment], rows: [[String]])
    /// `![alt](src)`, with src as the agent wrote it: mostly a path on the
    /// Mac, which ThreadPictures swaps for what the runner uploaded.
    case image(alt: String, src: String)

    public enum Alignment: Sendable, Hashable { case leading, center, trailing }

    /// Past this a fence stays code (Pele refuses more itself).
    public static let maxRichSource = 50_000

    public enum RichKind: String, Sendable, Hashable {
        case mermaid, html

        /// The fence's info string: its first word, in any case.
        public init?(info: String) {
            guard let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first else { return nil }
            self.init(rawValue: word.lowercased())
        }
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var parser = Parser(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return parser.run()
    }
}

/// Finds `![alt](src)` and `![alt](<src> "title")`, as the runner does
/// (MARKDOWN_IMAGE in runner/src/share-images.ts), so src is the same string
/// on both sides. Not inside a code span, where it's only being talked about.
enum InlineImages {
    enum Piece: Equatable { case words(String), image(alt: String, src: String) }

    static func split(_ text: String) -> [Piece] {
        guard text.contains("![") else { return [.words(text)] }
        var pieces: [Piece] = []
        var from = text.startIndex
        let codeSpans = text.ranges(of: /`+[^`]*`+/)
        for match in text.matches(of: /!\[([^\]]*)\]\(\s*(?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"]*")?\s*\)/) {
            if codeSpans.contains(where: { $0.overlaps(match.range) }) { continue }
            guard let src = match.2 ?? match.3 else { continue }
            add(text[from..<match.range.lowerBound], to: &pieces)
            pieces.append(.image(alt: String(match.1), src: String(src)))
            from = match.range.upperBound
        }
        add(text[from...], to: &pieces)
        return pieces
    }

    private static func add(_ words: Substring, to pieces: inout [Piece]) {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(.words(trimmed)) }
    }
}

private struct Parser {
    let lines: [String]
    var i = 0
    var blocks: [MarkdownBlock] = []
    /// Raw lines, so `flush` can see a hard break's two trailing spaces.
    var paragraph: [String] = []
    /// Indents of the open list levels, so a deeper indent nests one level
    /// whatever its width (2, 3 or 4 spaces).
    var listIndents: [Int] = []
    /// A wrapped line belongs to the list item above it, until a blank line.
    var lastWasListItem = false

    init(lines: [String]) { self.lines = lines }

    mutating func run() -> [MarkdownBlock] {
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = Self.indent(of: raw)

            if let fence = Self.fence(line) {
                flush()
                let info = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                let (body, closed) = code(fence: fence, indent: indent)
                // Drawn only once its fence is closed (a reply still
                // streaming in stays code) and not too big to draw, as on
                // the Mac (RichBlock.from).
                if closed, body.count <= MarkdownBlock.maxRichSource,
                   !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let kind = MarkdownBlock.RichKind(info: info) {
                    blocks.append(.rich(kind: kind, source: body))
                } else {
                    blocks.append(.code(body))
                }
                continue
            }
            if line.isEmpty {
                flush()
                lastWasListItem = false
                i += 1
                continue
            }
            if Self.isRule(line) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(MarkdownBlock.parse(quoteLines().joined(separator: "\n"))))
                continue
            }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.*?)(?:\s+#+)?$/) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                i += 1
                continue
            }
            if i + 1 < lines.count, line.contains("|"), let alignments = Self.delimiterRow(lines[i + 1]) {
                let header = Self.cells(line)
                if header.count == alignments.count {
                    flush()
                    blocks.append(table(header: header, alignments: alignments))
                    continue
                }
            }
            if let match = line.firstMatch(of: /^([-*+]|\d{1,9}[.)])\s+(.*)$/) {
                flush()
                var text = String(match.2)
                var task: Bool?
                if let box = text.firstMatch(of: /^\[([ xX])\]\s+/) {
                    task = box.1 != " "
                    text.removeSubrange(box.range)
                }
                let marker = match.1.first?.isNumber == true ? String(match.1.dropLast()) + "." : "•"
                // A picture in a list item goes straight under it, as there's
                // no drawing one among a line's words.
                let (words, images) = Self.wordsAndImages(text)
                let level = depth(for: indent)
                if !words.isEmpty || images.isEmpty {
                    blocks.append(.listItem(text: words, marker: marker, depth: level, task: task))
                }
                blocks.append(contentsOf: images)
                lastWasListItem = true
                i += 1
                continue
            }
            // A wrapped line of a list item, or an indented paragraph under
            // one after a blank line: it stays with the item.
            if case let .listItem(text, marker, depth, task) = blocks.last, paragraph.isEmpty,
               lastWasListItem || indent >= 2 {
                let joiner = lastWasListItem ? " " : "\n\n"
                let (words, images) = Self.wordsAndImages(line)
                if !words.isEmpty {
                    blocks[blocks.count - 1] = .listItem(text: text + joiner + words, marker: marker, depth: depth, task: task)
                }
                blocks.append(contentsOf: images)
                lastWasListItem = true
                i += 1
                continue
            }
            if indent == 0 { listIndents = [] }
            paragraph.append(raw)
            i += 1
        }
        flush()
        return blocks
    }

    /// Lines in a paragraph are joined with spaces, as GitHub shows a soft
    /// line break; two trailing spaces or a backslash keep the break.
    mutating func flush() {
        guard !paragraph.isEmpty else { return }
        var text = ""
        for (n, raw) in paragraph.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            text += line
            guard n < paragraph.count - 1 else { break }
            if raw.hasSuffix("  ") || line.hasSuffix("\\") {
                if line.hasSuffix("\\") { text.removeLast() }
                text += "\n"
            } else {
                text += " "
            }
        }
        for piece in InlineImages.split(text) {
            switch piece {
            case let .words(words): blocks.append(.paragraph(words))
            case let .image(alt, src): blocks.append(.image(alt: alt, src: src))
            }
        }
        paragraph = []
        lastWasListItem = false
    }

    static func wordsAndImages(_ text: String) -> (words: String, images: [MarkdownBlock]) {
        let pieces = InlineImages.split(text)
        let words = pieces.compactMap { if case let .words(w) = $0 { w } else { nil } }.joined(separator: " ")
        let images = pieces.compactMap { (piece: InlineImages.Piece) -> MarkdownBlock? in
            if case let .image(alt, src) = piece { .image(alt: alt, src: src) } else { nil }
        }
        return (words, images)
    }

    mutating func depth(for indent: Int) -> Int {
        while let last = listIndents.last, last > indent { listIndents.removeLast() }
        if listIndents.last != indent { listIndents.append(indent) }
        return listIndents.count - 1
    }

    /// The fenced block's lines, and whether its closing fence came.
    mutating func code(fence: String, indent: Int) -> (String, Bool) {
        i += 1
        var body: [String] = []
        var closed = false
        while i < lines.count {
            let raw = lines[i]
            i += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(fence), line.allSatisfy({ $0 == fence.first }) { closed = true; break }
            // Code fenced inside a list item is indented with it; take that off.
            var drop = min(indent, Self.indent(of: raw))
            var trimmed = Substring(raw)
            while drop > 0, trimmed.first == " " || trimmed.first == "\t" { trimmed.removeFirst(); drop -= 1 }
            body.append(String(trimmed))
        }
        return (body.joined(separator: "\n"), closed)
    }

    mutating func quoteLines() -> [String] {
        var out: [String] = []
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(">") else { break }
            var rest = line.dropFirst()
            if rest.first == " " { rest.removeFirst() }
            out.append(String(rest))
            i += 1
        }
        return out
    }

    mutating func table(header: [String], alignments: [MarkdownBlock.Alignment]) -> MarkdownBlock {
        i += 2
        var rows: [[String]] = []
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("|") else { break }
            var row = Self.cells(line)
            // GitHub pads short rows and drops extra cells.
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            i += 1
        }
        return .table(header: header, alignments: alignments, rows: rows)
    }

    static func indent(of line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func fence(_ line: String) -> String? {
        if let match = line.firstMatch(of: /^(`{3,}|~{3,})/) { return String(match.1) }
        return nil
    }

    static func isRule(_ line: String) -> Bool {
        line.wholeMatch(of: /(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,}/) != nil
    }

    /// `| --- | :-: | --: |`, with or without the outer pipes.
    static func delimiterRow(_ raw: String) -> [MarkdownBlock.Alignment]? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-"), line.contains("|") || line.hasPrefix(":") || line.hasPrefix("-") else { return nil }
        var alignments: [MarkdownBlock.Alignment] = []
        for cell in cells(line) {
            guard cell.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// A row's cells: split on pipes that aren't escaped, outer pipes optional.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for c in line {
            if escaped { cell.append(c == "|" ? "|" : "\\\(c)"); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "|" { cells.append(cell); cell = ""; continue }
            cell.append(c)
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|") && !line.hasSuffix("\\|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
