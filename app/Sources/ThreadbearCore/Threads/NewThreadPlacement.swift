import Foundation

/// Where the composer goes in the detail pane: at the bottom under a
/// thread, or about 40% of the way down an empty new thread with a heading
/// above it and a line below it, as Codex and Claude do.
public enum ComposerPlacementMath {
    /// About half the composer's height with an empty box. The composer's
    /// top is placed rather than its middle, so it grows downwards as Mike
    /// types instead of creeping up the pane.
    public static let halfEmptyComposer: Double = 56
    /// Room kept above the heading in a short window.
    public static let headingClearance: Double = 40

    /// The composer's top, measured from the top of the pane.
    public static func composerTop(paneHeight: Double, composerHeight: Double, centred: Bool,
                                   headingHeight: Double = 0, noteHeight: Double = 0) -> Double {
        let bottom = max(0, paneHeight - composerHeight)
        guard centred else { return bottom }
        let preferred = (paneHeight * 0.4 - halfEmptyComposer).rounded()
        let highest = headingHeight + headingClearance
        // Never so high the heading is cut off, never so low the line under
        // it (or the composer itself) goes off the bottom.
        return max(0, min(max(preferred, highest), paneHeight - composerHeight - noteHeight))
    }
}
