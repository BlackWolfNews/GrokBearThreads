import Foundation

/// Column widths for a markdown table.
public enum TableColumns {
    /// Each column gets its natural (one-line) width while they all fit in
    /// `budget`. When they don't, the narrow columns keep theirs and the
    /// wide ones share what's left equally and wrap, so a short "Before"
    /// column never wraps to make room for a long description.
    public static func fit(_ natural: [Double], into budget: Double) -> [Double] {
        guard budget > 0, natural.reduce(0, +) > budget else { return natural }
        var widths = natural
        var remaining = budget
        var open = natural.indices.sorted { natural[$0] < natural[$1] }
        while let narrowest = open.first {
            let share = remaining / Double(open.count)
            if natural[narrowest] <= share {
                remaining -= natural[narrowest]
                open.removeFirst()
            } else {
                for index in open { widths[index] = share }
                break
            }
        }
        return widths
    }
}
