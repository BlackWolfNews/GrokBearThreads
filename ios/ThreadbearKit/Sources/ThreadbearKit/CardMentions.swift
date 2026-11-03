import Foundation

/// Notion cards mentioned in a message, as on the Mac (the Mac's copy is
/// app/Sources/ThreadbearCore/Threads/CardMentions.swift). A message holds a
/// plain Markdown link, so the agent gets an address it can read the card
/// from; Mike's bubble draws it as a chip.
public enum CardMentions {
    public struct Mention: Sendable, Hashable {
        /// The whole link in the text, UTF-16.
        public var range: NSRange
        public var title: String
        public var url: String
    }

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
