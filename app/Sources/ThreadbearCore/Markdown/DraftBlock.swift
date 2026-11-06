import Foundation

/// A ```slack, ```email or ```draft block in a reply: text the agent has
/// written for Mike to send somewhere else. It's shown the way it'll go
/// out, every line where the agent put it (a reply's own Markdown joins
/// lines up, which ran a Slack draft's "•" lines into one paragraph, 6 Nov),
/// in a box with a Copy button. A ```slack one also draws Slack's own
/// formatting: *bold*, _italic_, ~strike~, `code` and <url|label> links.
///
/// The phone (ios/ThreadbearKit, DraftBlock.swift) and the website
/// (web/src/draft.ts) parse it the same way; keep the three together.
public struct DraftBlock: Hashable, Sendable {
    public enum Kind: String, Sendable { case slack, email, draft }

    public let kind: Kind
    public let source: String

    public init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
    }

    /// The draft for a fence's info string (only the first word counts),
    /// or nil for any other fence.
    public static func from(language: String?, code: String) -> DraftBlock? {
        guard let word = language?.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first?.lowercased(),
              let kind = Kind(rawValue: word) else { return nil }
        var source = code.replacingOccurrences(of: "\r\n", with: "\n")
        while source.hasSuffix("\n") { source.removeLast() }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DraftBlock(kind: kind, source: source)
    }

    /// Whether a block of a reply's text could hold one, so only those
    /// are checked for a closed fence.
    public static func mayHold(_ text: String) -> Bool {
        guard text.contains("```") || text.contains("~~~") else { return false }
        let lowered = text.lowercased()
        return lowered.contains("slack") || lowered.contains("email") || lowered.contains("draft")
    }

    /// What the box's header calls it.
    public var label: String {
        switch kind {
        case .slack: return "Slack draft"
        case .email: return "Email draft"
        case .draft: return "Draft"
        }
    }

    /// A run of a line with one look.
    public struct Span: Hashable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var strike = false
        public var code = false
        /// http(s) or mailto only.
        public var link: URL?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: URL? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.strike = strike
            self.code = code
            self.link = link
        }
    }

    public struct Line: Hashable, Sendable {
        public var spans: [Span]
        /// A Slack "> " line, drawn with a bar.
        public var quote = false
    }

    /// The draft's lines as they're shown. An email or plain draft is its
    /// text as it is (bare addresses are linked when it's drawn); a Slack
    /// one has its formatting and <...> tokens worked out.
    public var lines: [Line] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            guard kind == .slack else { return Line(spans: [Span(line)]) }
            if line.hasPrefix("> ") || line == ">" || line.hasPrefix("&gt; ") {
                let rest = line.hasPrefix("&gt; ") ? String(line.dropFirst(5)) : String(line.dropFirst(min(2, line.count)))
                return Line(spans: Self.slackSpans(rest), quote: true)
            }
            return Line(spans: Self.slackSpans(line))
        }
    }

    /// What Copy puts on the clipboard as plain text. A Slack draft keeps
    /// its *bold* and _italic_ (Slack's message box formats those as it
    /// sends) but its <url|label> links become "label (url)", which pasted
    /// as plain text would otherwise stay as typed.
    public var plainText: String {
        guard kind == .slack else { return source }
        return source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            Self.replaceTokens(String(line)) { token in
                switch token {
                case let .link(url, label): return label == url.absoluteString || label.isEmpty ? url.absoluteString : "\(label) (\(url.absoluteString))"
                case let .mention(text): return text
                }
            }
        }.joined(separator: "\n")
    }

    /// The same as HTML, put on the clipboard beside the plain text, so
    /// pasting into Slack or Mail keeps the bold and the links.
    public var html: String {
        let body = lines.map { line -> String in
            let inner = line.spans.map(Self.html).joined()
            return line.quote ? "<blockquote>\(inner)</blockquote>" : inner
        }
        // Quotes are blocks of their own, so no <br> beside one.
        var out = ""
        for (index, part) in body.enumerated() {
            out += part
            if index < body.count - 1, !part.hasPrefix("<blockquote>"), !body[index + 1].hasPrefix("<blockquote>") { out += "<br>" }
        }
        return "<meta charset=\"utf-8\"><div>\(out)</div>"
    }

    private static func html(_ span: Span) -> String {
        var text = escape(span.text)
        if span.code { text = "<code>\(text)</code>" }
        if span.strike { text = "<s>\(text)</s>" }
        if span.italic { text = "<i>\(text)</i>" }
        if span.bold { text = "<b>\(text)</b>" }
        if let link = span.link { text = "<a href=\"\(escape(link.absoluteString))\">\(text)</a>" }
        return text
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Slack's formatting

    enum Token {
        case link(URL, String)
        /// <@U123>, <#C123|general>, <!here>: shown as their words.
        case mention(String)
    }

    /// A <...> token: a link to a web page or a mail address, or a mention.
    /// Anything else between angle brackets is left as written.
    static func token(_ inside: String) -> Token? {
        let parts = inside.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 ? parts[1] : nil
        if let first = target.first, first == "@" || first == "#" || first == "!" {
            let name = target.dropFirst()
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            if let label, !label.isEmpty { return .mention(first == "#" && !label.hasPrefix("#") ? "#\(label)" : label) }
            if first == "!" {
                // <!subteam^S123> and <!date^...> carry a label or nothing useful.
                return .mention("@\(name.split(separator: "^").first ?? name)")
            }
            return .mention("\(first)\(name)")
        }
        guard !target.contains(" "), let url = URL(string: target), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        let shown = label.map(decode) ?? (scheme == "mailto" ? String(target.dropFirst("mailto:".count)) : target)
        return .link(url, shown)
    }

    /// The line with each <...> token replaced, and Slack's escapes
    /// (&lt; &gt; &amp;) read back.
    static func replaceTokens(_ line: String, _ replace: (Token) -> String) -> String {
        var out = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "<") {
            out += decode(String(rest[..<open]))
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: ">"), let token = token(String(after[..<close])) else {
                out += "<"
                rest = after
                continue
            }
            out += replace(token)
            rest = after[after.index(after: close)...]
        }
        return out + decode(String(rest))
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A Slack line's spans: links and mentions first, then *bold*,
    /// _italic_, ~strike~ and `code` in the words between them.
    static func slackSpans(_ line: String) -> [Span] {
        var spans: [Span] = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "<") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: ">"), let token = token(String(after[..<close])) else {
                // Not a token: the "<" is a word like any other.
                spans += emphasis(String(rest[...open]))
                rest = after
                continue
            }
            spans += emphasis(String(rest[..<open]))
            switch token {
            case let .link(url, label): spans.append(Span(label.isEmpty ? url.absoluteString : label, link: url))
            case let .mention(text): spans.append(Span(text, bold: true))
            }
            rest = after[after.index(after: close)...]
        }
        spans += emphasis(String(rest))
        return merge(spans)
    }

    /// Joins neighbouring spans that look the same (a "<" that wasn't a
    /// token leaves the words around it in pieces).
    private static func merge(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for span in spans where !span.text.isEmpty {
            if var last = out.last, last.bold == span.bold, last.italic == span.italic, last.strike == span.strike,
               last.code == span.code, last.link == span.link {
                last.text += span.text
                out[out.count - 1] = last
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Slack's emphasis: a marker counts when it opens at the start or
    /// after a space or punctuation, is followed by a non-space, and closes
    /// on the same line before a space, punctuation or the end. So
    /// "2*3*4" and "snake_case_name" stay as written.
    static func emphasis(_ text: String, _ base: Span = Span("")) -> [Span] {
        let chars = Array(text)
        var spans: [Span] = []
        var plain = ""
        var i = 0
        func flush() {
            guard !plain.isEmpty else { return }
            var span = base
            span.text = decode(plain)
            spans.append(span)
            plain = ""
        }
        while i < chars.count {
            let c = chars[i]
            if "*_~`".contains(c), opens(chars, i), let end = closing(chars, from: i, marker: c) {
                flush()
                let inner = String(chars[(i + 1)..<end])
                var span = base
                switch c {
                case "`":
                    span.code = true
                    span.text = decode(inner)
                    spans.append(span)
                default:
                    if c == "*" { span.bold = true } else if c == "_" { span.italic = true } else { span.strike = true }
                    spans += emphasis(inner, span)
                }
                i = end + 1
                continue
            }
            plain.append(c)
            i += 1
        }
        flush()
        return spans
    }

    private static func isWordy(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func opens(_ chars: [Character], _ i: Int) -> Bool {
        guard i + 1 < chars.count, !chars[i + 1].isWhitespace, chars[i + 1] != chars[i] else { return false }
        return i == 0 || !isWordy(chars[i - 1])
    }

    private static func closing(_ chars: [Character], from start: Int, marker: Character) -> Int? {
        var j = start + 2
        while j < chars.count {
            if chars[j] == marker, !chars[j - 1].isWhitespace, j + 1 == chars.count || !isWordy(chars[j + 1]) { return j }
            j += 1
        }
        return nil
    }
}
