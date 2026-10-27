import Foundation

/// Which of a thread's panels is showing, and how wide the pane is.
public enum PanelChoice {
    /// The panel to show: the one chosen for this thread if it's still
    /// there, else the first. Nil with no panels.
    public static func active(in panels: [Panel], remembered: String?) -> Panel? {
        if let remembered, let hit = panels.first(where: { $0.id == remembered }) { return hit }
        return panels.first
    }

    public static let defaultWidth: Double = 420
    public static let minWidth: Double = 280
    /// What the transcript column keeps at least, so a pane can't squeeze
    /// it to nothing on a small window.
    public static let minTranscriptWidth: Double = 360

    /// A pane width Mike dragged to, kept inside what the pane's column
    /// allows.
    public static func clampedWidth(_ width: Double, paneColumnWidth: Double) -> Double {
        let most = max(minWidth, paneColumnWidth - minTranscriptWidth)
        return min(max(width, minWidth), most)
    }
}
