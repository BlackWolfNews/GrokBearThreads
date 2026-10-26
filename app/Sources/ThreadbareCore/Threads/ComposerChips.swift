import Foundation

/// Labels and sizes for the composer. Its chips stay short and quiet; the
/// full folder path, email and model id go in their tooltips and menus.
public enum ComposerChips {
    /// The folder chip: the last path component ("misc" for
    /// "/Users/mike/dev/me/misc"), "/" for the root.
    public static func folder(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return "Folder" }
        guard trimmed != "/" else { return "/" }
        return (trimmed as NSString).lastPathComponent
    }

    /// The model chip. No model means the account's own default, whose name
    /// the app doesn't know, so it reads "Default". A menu alias reads as a
    /// word ("Opus") and a full Claude id as family and version
    /// ("claude-opus-5-5" is "Opus 5.5", with any date suffix dropped).
    /// Anything else is shown as it is.
    public static func model(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Default" }
        if model.allSatisfy(\.isLetter) { return model.capitalized }
        var parts = model.split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return model }
        parts.removeFirst()
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter), parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return model }
        return family.capitalized + " " + parts.dropFirst().joined(separator: ".")
    }

    /// Whether there's anything to send: some words or at least one image.
    public static func canSend(text: String, imageCount: Int) -> Bool {
        imageCount > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text box is at least two lines tall so it reads as a place to
    /// write, grows with the text, and scrolls past ten lines.
    public static let minLines: CGFloat = 2
    public static let maxLines: CGFloat = 10

    public static func boxHeight(textHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let low = (lineHeight * minLines).rounded(.up)
        let high = (lineHeight * maxLines).rounded(.up)
        return min(high, max(low, textHeight.rounded(.up)))
    }
}
