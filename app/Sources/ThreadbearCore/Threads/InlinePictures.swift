import Foundation

/// Pictures among a message's words (docs/protocol.md, "Pictures in a
/// message"), so Mike can point at two or more in one message, as T3 Code
/// let him (1 Nov 2026).
///
/// A draft holds each picture as a mark in its text: U+FFFC, the character
/// the composer's chip attachments are, the k-th mark standing for the
/// k-th picture. Typed or pasted words can't make one, so a mark is always
/// a chip. A message holds `[Picture N]` markers instead, standing for
/// `images[N-1]`: they read as words everywhere else (the phone,
/// `read_thread`, the archive), and the runner puts each picture straight
/// after its marker when it goes to the agent.
public enum InlinePictures {
    public static let mark: Unicode.Scalar = "\u{FFFC}"
    public static let markString = String(Character(mark))

    public static func marker(_ number: Int) -> String { "[Picture \(number)]" }

    /// The same marker the runner reads (runner/src/pictures.ts).
    nonisolated(unsafe) private static let markerPattern = try! NSRegularExpression(pattern: #"\[Picture (\d{1,3})\]"#)

    /// How many pictures a draft's text places.
    public static func markCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $1 == mark ? $0 + 1 : $0 }
    }

    /// A draft's text put right for `imageCount` pictures: one mark each.
    /// Spare marks go (words carried somewhere without their pictures);
    /// a picture with no mark (added from outside the composer) gets one
    /// at the end.
    public static func normalized(_ text: String, imageCount: Int) -> String {
        let marks = markCount(text)
        if marks == imageCount { return text }
        if marks > imageCount {
            var kept = 0
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if scalar == mark {
                    kept += 1
                    if kept > imageCount { continue }
                }
                scalars.append(scalar)
            }
            return String(scalars)
        }
        var out = text
        for _ in marks..<imageCount { out = appending(markString, to: out) }
        return out
    }

    /// `piece` after `text`, with a space between unless `text` is empty
    /// or ends in whitespace.
    public static func appending(_ piece: String, to text: String) -> String {
        guard let last = text.unicodeScalars.last, !CharacterSet.whitespacesAndNewlines.contains(last) else { return text + piece }
        return text + " " + piece
    }

    /// A draft's words as they're sent: its k-th mark becomes
    /// `[Picture first+k]`, as a message's pictures can come after others
    /// (an ask box's). With nothing but pictures and spaces it's "", the
    /// pictures alone, as a message of only pictures always was.
    public static func sentText(_ text: String, first: Int = 1) -> String {
        guard text.unicodeScalars.contains(mark) else { return text }
        if text.unicodeScalars.allSatisfy({ $0 == mark || CharacterSet.whitespacesAndNewlines.contains($0) }) { return "" }
        return messageText(text, first: first)
    }

    /// A draft's text with its k-th mark as `[Picture first+k]`.
    public static func messageText(_ text: String, first: Int = 1) -> String {
        guard text.unicodeScalars.contains(mark) else { return text }
        var out = ""
        var number = first
        for scalar in text.unicodeScalars {
            if scalar == mark {
                out += marker(number)
                number += 1
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A draft's words without its pictures, for a schedule, which can't
    /// take them.
    public static func words(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != mark }))
    }

    /// The markers in a message that place one of its `imageCount`
    /// pictures, in the order they come: the first naming each picture,
    /// as the runner reads them. A marker naming no picture, or one
    /// already placed, is words. UTF-16 ranges, for attributed strings.
    public static func markers(in text: String, imageCount: Int) -> [(range: NSRange, index: Int)] {
        guard imageCount > 0, text.contains("[Picture ") else { return [] }
        let ns = text as NSString
        var placed = Set<Int>()
        var found: [(NSRange, Int)] = []
        for match in markerPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let number = Int(ns.substring(with: match.range(at: 1))) else { continue }
            let index = number - 1
            guard index >= 0, index < imageCount, placed.insert(index).inserted else { continue }
            found.append((match.range, index))
        }
        return found
    }

    /// A message's words and pictures back in the composer, to edit it:
    /// each placed picture's mark where its marker was, the pictures in
    /// the marks' order. A picture no marker placed went before the words,
    /// so its mark goes at the start.
    public static func draft(text: String, images: [ImageRef]) -> (text: String, images: [ImageRef]) {
        // A mark already in a message's words would stand for the wrong picture.
        let text = words(text)
        let found = markers(in: text, imageCount: images.count)
        let ns = NSMutableString(string: text)
        for marker in found.reversed() { ns.replaceCharacters(in: marker.range, with: markString) }
        let placed = Set(found.map(\.index))
        let first = images.indices.filter { !placed.contains($0) }
        var words = ns as String
        if !first.isEmpty {
            let marks = String(repeating: markString, count: first.count)
            words = words.isEmpty ? marks : marks + " " + words
        }
        return (words, first.map { images[$0] } + found.map { images[$0.index] })
    }

    /// The draft's text without the `index`-th mark, and with one space
    /// beside it, so taking a chip out of "this \u{FFFC} that" leaves "this that".
    public static func removingMark(_ index: Int, from text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        var seen = 0
        guard let at = scalars.indices.first(where: { i in
            guard scalars[i] == mark else { return false }
            defer { seen += 1 }
            return seen == index
        }) else { return text }
        scalars.remove(at: at)
        if at < scalars.count, scalars[at] == " " {
            scalars.remove(at: at)
        } else if at > 0, scalars[at - 1] == " " {
            scalars.remove(at: at - 1)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
