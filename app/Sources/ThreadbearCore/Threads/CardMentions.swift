import Foundation

/// Notion cards and other threads mentioned in a message. A message always
/// holds a plain Markdown link (`ProjectTask.reference`,
/// `CardMentions.threadReference`), so the agent gets an address it can
/// read the card or thread from, and the phone, `read_thread` and the
/// archive get ordinary words. The composer and Mike's bubble draw these as
/// chips.
public enum CardMentions {
    public enum Kind: Sendable, Hashable {
        case card
        /// Another thread, as a `thread:<id>` link (WorkLinks), which the
        /// transcript already opens in the app.
        case thread
    }

    public struct Mention: Sendable, Hashable {
        /// The whole link in the text, UTF-16, for attributed strings.
        public var range: NSRange
        public var title: String
        public var url: String
        public var kind: Kind = .card
    }

    // A title with escaped brackets allowed in it, then an https address on
    // Notion's own domains or a thread: link. Nothing but a link's end or a
    // space ends the address, and the domain has to finish where the path
    // starts, so notion.so.example.com is no card.
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!!)\[((?:[^\]\\\n]|\\.)+)\]\((https://(?:[A-Za-z0-9-]+\.)*notion\.(?:so|site|com)/[^\s)]*|thread:[A-Za-z0-9_-]+)\)"#)

    public static func find(in text: String) -> [Mention] {
        guard text.contains("notion.") || text.contains("](thread:") else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let title = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
            let url = ns.substring(with: match.range(at: 2))
            return Mention(range: match.range, title: title, url: url, kind: url.hasPrefix("thread:") ? .thread : .card)
        }
    }

    /// How a pasted thread id goes into a message: a link the agent can read
    /// the id from and the app draws as a chip with the thread's title.
    public static func threadReference(id: String, title: String) -> String {
        let words = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = (words.isEmpty ? "Thread" : words)
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(name)](thread:\(id))"
    }

    /// The thread a paste names on its own: a bare id ("Copy thread id"),
    /// `thread:<id>` or `threadbear://thread/<id>`. Only ids of known
    /// threads count, so any other UUID pasted stays words.
    public static func pastedThreadId(_ pasted: String, known: (String) -> Bool) -> String? {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["threadbear://thread/", "thread:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        guard !text.isEmpty, text.count <= 64,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        if known(text) { return text }
        return known(text.lowercased()) ? text.lowercased() : nil
    }
}
