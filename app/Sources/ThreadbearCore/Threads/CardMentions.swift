import Foundation

/// Notion cards mentioned in a message. A message always holds a plain
/// Markdown link (`ProjectTask.reference`), so the agent gets an address it
/// can read the card from, and the phone, `read_thread` and the archive get
/// ordinary words. The composer and Mike's bubble draw these as chips.
public enum CardMentions {
    public struct Mention: Sendable, Hashable {
        /// The whole link in the text, UTF-16, for attributed strings.
        public var range: NSRange
        public var title: String
        public var url: String
    }

    // A title with escaped brackets allowed in it, then an https address on
    // Notion's own domains. Nothing but a link's end or a space ends the
    // address, and the domain has to finish where the path starts, so
    // notion.so.example.com is no card.
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!!)\[((?:[^\]\\\n]|\\.)+)\]\((https://(?:[A-Za-z0-9-]+\.)*notion\.(?:so|site|com)/[^\s)]*)\)"#)

    public static func find(in text: String) -> [Mention] {
        guard text.contains("notion.") else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let title = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
            return Mention(range: match.range, title: title, url: ns.substring(with: match.range(at: 2)))
        }
    }
}
