import Foundation

/// What the pane beside the transcript shows: the thread's highlights, one
/// of its panels, or the patches that apply to it. Each has a button on the
/// right-hand rail.
public enum PaneSection: Hashable, Sendable {
    case highlights
    case panel(String)
    case patches

    /// As kept in the app's per-thread choice and named by the automation.
    public var id: String {
        switch self {
        case .highlights: Self.highlightsId
        case .patches: Self.patchesId
        case .panel(let id): id
        }
    }

    public init(id: String) {
        switch id {
        case Self.highlightsId: self = .highlights
        case Self.patchesId: self = .patches
        default: self = .panel(id)
        }
    }

    public static let highlightsId = "threadbear.highlights"
    public static let patchesId = "threadbear.patches"
}

/// Which section of the pane is showing, and how wide the pane is.
public enum PanelChoice {
    /// The panel to show: the one chosen for this thread if it's still
    /// there, else the first. Nil with no panels.
    public static func active(in panels: [Panel], remembered: String?) -> Panel? {
        if let remembered, let hit = panels.first(where: { $0.id == remembered }) { return hit }
        return panels.first
    }

    /// The section to show: the one chosen for this thread while it's still
    /// there, else Highlights, which every thread has.
    public static func section(panels: [Panel], hasPatches: Bool, remembered: String?) -> PaneSection {
        guard let remembered else { return .highlights }
        switch PaneSection(id: remembered) {
        case .highlights: return .highlights
        case .patches: return hasPatches ? .patches : .highlights
        case .panel("threadbear.browser"): return .panel("threadbear.browser")
        case .panel(let id): return panels.contains { $0.id == id } ? .panel(id) : .highlights
        }
    }

    /// A click on a rail button, VS Code's way: the section that's showing
    /// collapses the pane (the rail stays), any other opens it there.
    public static func click(_ clicked: PaneSection, showing: PaneSection, shown: Bool) -> (section: PaneSection, shown: Bool) {
        if shown && clicked == showing { return (showing, false) }
        return (clicked, true)
    }

    /// 360, not the 420 it was when only a few threads had a pane: now
    /// every thread has one, and at 420 the composer's chips were cut to
    /// "si" and "..." on a 1240 pt window.
    public static let defaultWidth: Double = 360
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
