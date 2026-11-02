import Foundation

/// The sums behind the board in Highlights, kept apart from the view so they
/// can be tested.
public enum BoardLayout {
    /// How wide each open column is. They share the panel when they all fit
    /// at `minimum`; otherwise each stays at `minimum` and the board scrolls.
    public static func columnWidth(available: Double, columns: Int, folded: Int, spacing: Double, foldedWidth: Double, minimum: Double) -> Double {
        guard columns > 0, available > 0 else { return minimum }
        let gaps = Double(max(0, columns + folded - 1)) * spacing
        let share = (available - gaps - Double(folded) * foldedWidth) / Double(columns)
        return max(minimum, share)
    }

    /// Where an arrow scrolls to: the next column's edge in that direction,
    /// so a click never leaves a column cut in half, stopping at the ends.
    public static func page(from offset: Double, by direction: Int, step: Double, maximum: Double) -> Double {
        guard step > 0 else { return 0 }
        let position = offset / step
        let target = direction > 0 ? (position + 0.001).rounded(.down) + 1 : (position - 0.001).rounded(.up) - 1
        // Near the far end, the last stop isn't on a column's edge, so going
        // back from it lands on the column it's showing.
        if direction < 0, offset >= maximum, maximum > 0 {
            return min(maximum, max(0, (maximum / step).rounded(.down) * step))
        }
        return min(maximum, max(0, target * step))
    }

    /// A draft with a card mentioned at its end, spaced so Mike can carry on
    /// typing. A card already in it isn't added again.
    public static func adding(_ reference: String, to draft: String) -> String {
        if draft.contains(reference) { return draft }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reference + " " }
        let separator = draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + reference + " "
    }
}
