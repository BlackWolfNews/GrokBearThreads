import Foundation

/// Shift-Return in the message box carries a markdown list on, like T3 Code
/// and Claude's apps: after "1. foo" the new line starts "2. ", after
/// "- foo" it starts "- ", and a checkbox item starts an unticked one.
/// Shift-Return on an item with nothing in it takes the marker off instead,
/// which is how you get out of the list.
public enum ListContinuation {
    /// Replace `range` (UTF-16, as NSTextView counts) with `text`.
    public struct Edit: Equatable {
        public let range: NSRange
        public let text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// Indent, then a bullet or a number (nine digits at most, as in
    /// CommonMark) with "." or ")", the space after it, and an optional
    /// checkbox. Needs the space, so "**bold**" and "2.5" aren't lists.
    private static let marker = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|([0-9]{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#
    )

    /// The edit for Shift-Return with `selection` in `text`, or nil when the
    /// caret's line isn't a list item and it's a plain new line.
    public static func newline(in text: String, selection: NSRange) -> Edit? {
        let string = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= string.length else { return nil }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = NSRange(location: lineStart, length: selection.location - lineStart)
        guard let match = marker.firstMatch(in: text, range: before) else { return nil }

        // An empty item: nothing typed after the marker, before or after
        // the caret. Taking the marker off ends the list.
        let lineEnd = string.lineRange(for: NSRange(location: NSMaxRange(selection), length: 0))
        let after = string.substring(with: NSRange(location: NSMaxRange(selection), length: NSMaxRange(lineEnd) - NSMaxRange(selection)))
        if match.range.length == before.length, after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Edit(range: before, text: "")
        }

        func group(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : string.substring(with: range)
        }
        var next = group(1)
        if let number = Int(group(3)) {
            next += String(number + 1) + group(4)
        } else {
            next += group(2)
        }
        next += group(5)
        if !group(6).isEmpty {
            // Keep the spacing after the box, but the new one starts unticked.
            next += "[ ]" + group(6).dropFirst(3)
        }
        return Edit(range: selection, text: "\n" + next)
    }
}
