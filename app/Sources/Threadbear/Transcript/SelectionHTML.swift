import AppKit

/// A transcript selection as a small HTML fragment, for the pasteboard.
///
/// Why: AppKit's own copy writes plain text and RTF, and Slack, Chrome and
/// most web apps only read links and formatting from HTML, so a pasted
/// reply lost its links ("Fireside Chat shorts" arrived as bare words).
/// We build the HTML ourselves rather than use NSAttributedString's HTML
/// export, which carries the dark theme's colours and fonts along and
/// pastes white text into a white document.
enum SelectionHTML {
    static func html(_ selection: NSAttributedString) -> String {
        // Runs split on attributes HTML doesn't show (an inline code's
        // background ends a character early), so neighbours with the same
        // tags join up before wrapping, or `tb land` copies as two codes.
        var spans: [(tags: [(open: String, close: String)], text: String)] = []
        let whole = NSRange(location: 0, length: selection.length)
        selection.enumerateAttributes(in: whole) { attributes, range, _ in
            var text = (selection.string as NSString).substring(with: range)
            // A card chip is one U+FFFC; it copies as its title, as the
            // plain text does. Pictures and other attachments drop out.
            if let title = attributes[.tbCardChip] as? String {
                text = title
            } else {
                text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
            guard !text.isEmpty else { return }

            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var tags: [(open: String, close: String)] = []
            if let url = webLink(attributes[.link]) { tags.append(("<a href=\"\(escape(url.absoluteString))\">", "</a>")) }
            if traits.contains(.monoSpace) {
                tags.append(("<code>", "</code>"))
            } else {
                if traits.contains(.bold) { tags.append(("<b>", "</b>")) }
                if traits.contains(.italic) { tags.append(("<i>", "</i>")) }
            }
            if let last = spans.last, last.tags.map(\.open) == tags.map(\.open) {
                spans[spans.count - 1].text += text
            } else {
                spans.append((tags, text))
            }
        }
        let body = spans.map { span in
            let open = span.tags.map(\.open).joined()
            let close = span.tags.reversed().map(\.close).joined()
            // Each line wraps on its own, so a tag never spans a <br>.
            return span.text.components(separatedBy: "\n")
                .map { $0.isEmpty ? "" : open + escape($0) + close }
                .joined(separator: "<br>")
        }.joined()
        return "<meta charset=\"utf-8\">" + body
    }

    /// Only links that mean something off this Mac: a file path or an
    /// in-app link pasted into Slack would be a dead link.
    private static func webLink(_ value: Any?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
