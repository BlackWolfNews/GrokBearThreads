import Foundation

/// A panel's id. The app decides what each one shows; the layout only says
/// where it sits.
public typealias PanelID = String

/// Which way a split lays out its children: side by side, or one above the other.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// A side of a group, or of the whole window, to dock against.
public enum DockEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// Left and top put the new panel first in the split.
    public var isLeading: Bool { self == .left || self == .top }
}

/// One or more panels in the same space, as tabs when there are several.
public struct DockGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var panels: [PanelID]
    public var selected: PanelID

    public init(id: String, panels: [PanelID], selected: PanelID? = nil) {
        self.id = id
        self.panels = panels
        self.selected = selected ?? panels.first ?? ""
    }
}

/// Children laid out along one axis, each taking a fraction of the space.
/// Fractions always add up to 1.
public struct DockSplit: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var axis: SplitAxis
    public var children: [DockNode]
    public var fractions: [Double]

    public init(id: String, axis: SplitAxis, children: [DockNode], fractions: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.fractions = fractions ?? Array(repeating: 1 / Double(max(children.count, 1)), count: children.count)
    }
}

/// The layout is a tree: splits all the way down to groups of panels. Any
/// depth is allowed; `normalised()` keeps it tidy (no empty groups, no
/// one-child splits, no split directly inside another along the same axis).
public indirect enum DockNode: Codable, Equatable, Sendable, Identifiable {
    case group(DockGroup)
    case split(DockSplit)

    public var id: String {
        switch self {
        case .group(let g): g.id
        case .split(let s): s.id
        }
    }
}

/// Where a dragged panel lands.
public enum DockDrop: Codable, Equatable, Sendable, Hashable {
    /// Beside a group, splitting the space it had.
    case edge(group: String, DockEdge)
    /// Into a group, as another tab.
    case tab(group: String)
    /// Trading places with the panel showing in a group.
    case swap(group: String)
    /// Along a whole side of the window, the full height or width.
    case window(DockEdge)
}

/// A panel taken out of the dock into a window of its own.
public struct DockFloat: Codable, Equatable, Sendable {
    public var panel: PanelID
    /// The window's frame on screen, AppKit's way up (origin bottom-left),
    /// so it opens there again next launch.
    public var frame: CGRect
    /// Where "Put Back" docks it: as a tab in the group it left, or along
    /// the side of the window it was nearest.
    public var home: DockDrop?
    /// For a home along a side of the window: the share of the window it
    /// had across that way, so it comes back the size it was.
    public var share: Double?

    public init(panel: PanelID, frame: CGRect, home: DockDrop? = nil, share: Double? = nil) {
        self.panel = panel
        self.frame = frame
        self.home = home
        self.share = share
    }
}

public struct DockLayout: Codable, Equatable, Sendable {
    public var root: DockNode
    /// Panels in windows of their own, oldest first. Each is still open
    /// (`contains` says so) but in no group.
    public var floating: [DockFloat]
    /// Panels that go without a title bar while they're on their own (the
    /// thread list doesn't need "Threads" over it). Kept per panel, not per
    /// place, so it follows the panel when it's moved.
    public var hiddenTitles: Set<PanelID>

    public init(root: DockNode, hiddenTitles: Set<PanelID> = [], floating: [DockFloat] = []) {
        self.root = root
        self.hiddenTitles = hiddenTitles
        self.floating = floating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(DockNode.self, forKey: .root)
        // Not in layouts saved before titles could be hidden.
        hiddenTitles = try c.decodeIfPresent(Set<PanelID>.self, forKey: .hiddenTitles) ?? []
        // Nor in those saved before panels could have windows of their own.
        floating = try c.decodeIfPresent([DockFloat].self, forKey: .floating) ?? []
    }

    /// Whether a group gets its title bar. Always with tabs: they're how you
    /// switch between its panels.
    public func showsHeader(_ group: DockGroup) -> Bool {
        group.panels.count > 1 || !hiddenTitles.contains(group.selected)
    }

    public mutating func setTitleHidden(_ panel: PanelID, _ hidden: Bool) {
        if hidden { hiddenTitles.insert(panel) } else { hiddenTitles.remove(panel) }
    }

    // MARK: Reading

    /// Every panel in the layout, in tree order, then those in windows of
    /// their own.
    public var panels: [PanelID] { Self.panels(in: root) + floating.map(\.panel) }

    /// Open, in the dock or a window of its own.
    public func contains(_ panel: PanelID) -> Bool { group(containing: panel) != nil || isFloating(panel) }

    /// In a window of its own rather than the dock.
    public func isFloating(_ panel: PanelID) -> Bool { floating.contains { $0.panel == panel } }

    public func group(id: String) -> DockGroup? { Self.groups(in: root).first { $0.id == id } }

    public func group(containing panel: PanelID) -> DockGroup? {
        Self.groups(in: root).first { $0.panels.contains(panel) }
    }

    public var groups: [DockGroup] { Self.groups(in: root) }

    /// The tree in one line, for logs and the app's dump: rows and
    /// columns with each child's share, tabs joined by "+" with the one
    /// showing starred, "(no title)" where it's hidden.
    /// `row[threads (no title) 29% | thread 47% | column[highlights+patches* 60% / convex 40%] 24%]`
    /// Panels in windows of their own follow, as `+ window[highlights]`.
    public var summary: String {
        let tree = Self.summary(root, hidden: hiddenTitles)
        return floating.isEmpty ? tree : tree + floating.map { " + window[\($0.panel)]" }.joined()
    }

    static func summary(_ node: DockNode, hidden: Set<PanelID>) -> String {
        switch node {
        case .group(let g):
            let tabs = g.panels.map { $0 + (g.panels.count > 1 && $0 == g.selected ? "*" : "") }.joined(separator: "+")
            return tabs + (g.panels.count == 1 && hidden.contains(g.selected) ? " (no title)" : "")
        case .split(let s):
            let parts = zip(s.children, s.fractions).map { "\(summary($0, hidden: hidden)) \(Int(($1 * 100).rounded()))%" }
            return (s.axis == .horizontal ? "row[" : "column[") + parts.joined(separator: s.axis == .horizontal ? " | " : " / ") + "]"
        }
    }

    /// The group in the window's top-left corner: the first child all the
    /// way down, whichever way each split runs.
    public var topLeadingGroupID: String {
        var node = root
        while case .split(let s) = node, let first = s.children.first { node = first }
        return node.id
    }

    /// False for a drop that would leave everything where it is, so the UI
    /// doesn't offer it.
    public func canDrop(_ panel: PanelID, _ drop: DockDrop) -> Bool {
        if isFloating(panel) {
            // From a window of its own, back into the dock: anywhere but a
            // swap, as there's no place in the dock to swap with.
            switch drop {
            case .edge(let target, _), .tab(let target): return group(id: target) != nil
            case .swap: return false
            case .window: return true
            }
        }
        guard let source = group(containing: panel) else { return false }
        switch drop {
        case .edge(let target, _):
            guard group(id: target) != nil else { return false }
            // Splitting a group by a panel it alone holds goes nowhere.
            return !(target == source.id && source.panels.count == 1)
        case .tab(let target), .swap(let target):
            return group(id: target) != nil && target != source.id
        case .window:
            // The only panel there is can't go anywhere else.
            if case .group(let g) = root, g.panels == [panel] { return false }
            return true
        }
    }

    /// Whether a panel in the dock can go into a window of its own: not the
    /// last one there, as the main window would have nothing in it.
    public func canFloat(_ panel: PanelID) -> Bool {
        guard group(containing: panel) != nil else { return false }
        if case .group(let g) = root, g.panels == [panel] { return false }
        return true
    }

    // MARK: Changing

    /// Takes a panel out of the dock into a window of its own at `frame`
    /// (on screen). For one that's already in a window, just moves it.
    public mutating func float(_ panel: PanelID, frame: CGRect, home: DockDrop? = nil, share: Double? = nil) {
        if let i = floating.firstIndex(where: { $0.panel == panel }) {
            floating[i].frame = frame
            return
        }
        guard canFloat(panel), let rest = Self.removing(panel, from: root) else { return }
        root = rest
        floating.append(DockFloat(panel: panel, frame: frame, home: home, share: share))
    }

    /// Moves a panel already in the layout. Does nothing for a drop
    /// `canDrop` refuses. `newID` names any group or split this makes.
    public mutating func move(_ panel: PanelID, _ drop: DockDrop, newID: () -> String = { UUID().uuidString }) {
        guard canDrop(panel, drop) else { return }
        if let i = floating.firstIndex(where: { $0.panel == panel }) {
            let float = floating.remove(at: i)
            // Back home along a side: the size it left at.
            insert(panel, drop, share: float.home == drop ? float.share : nil, newID: newID)
            return
        }
        if case .swap(let target) = drop {
            swap(panel, into: target)
            return
        }
        guard let rest = Self.removing(panel, from: root) else { return }
        root = rest
        insert(panel, drop, newID: newID)
    }

    /// Puts a panel that isn't in the layout yet (a new one, or one that was
    /// closed) somewhere. A panel already in it is moved instead.
    public mutating func add(_ panel: PanelID, _ drop: DockDrop, newID: () -> String = { UUID().uuidString }) {
        if contains(panel) {
            move(panel, drop, newID: newID)
        } else {
            insert(panel, drop, newID: newID)
        }
    }

    /// Takes a panel out, closing its window if it has one of its own. The
    /// last panel in the dock can't be closed: there'd be no layout left.
    public mutating func close(_ panel: PanelID) {
        if isFloating(panel) {
            floating.removeAll { $0.panel == panel }
            return
        }
        guard let rest = Self.removing(panel, from: root) else { return }
        root = rest
    }

    /// Shows a panel that's a tab in its group.
    public mutating func select(_ panel: PanelID) {
        root = Self.mapGroups(root) { g in
            var g = g
            if g.panels.contains(panel) { g.selected = panel }
            return g
        }
    }

    /// From a divider being dragged. Keeps the sum at 1.
    public mutating func setFractions(split id: String, _ fractions: [Double]) {
        root = Self.mapSplits(root) { s in
            guard s.id == id, s.children.count == fractions.count else { return s }
            var s = s
            s.fractions = Self.normalisedFractions(fractions)
            return s
        }
    }

    // MARK: Internals

    /// `share`: for a drop along a side of the window, how much of it the
    /// panel takes; a quarter if nil.
    private mutating func insert(_ panel: PanelID, _ drop: DockDrop, share: Double? = nil, newID: () -> String) {
        let fresh = DockNode.group(DockGroup(id: newID(), panels: [panel]))
        switch drop {
        case .edge(let target, let edge):
            root = Self.inserting(fresh, beside: target, edge, in: root, newID: newID)
        case .tab(let target):
            root = Self.mapGroups(root) { g in
                guard g.id == target else { return g }
                var g = g
                g.panels.append(panel)
                g.selected = panel
                return g
            }
        case .swap:
            break
        case .window(let edge):
            // A new outer child takes a quarter (or its old share); the
            // rest keeps its proportions.
            let take = min(max(share ?? 0.25, 0.1), 0.9)
            if case .split(var s) = root, s.axis == edge.axis {
                s.fractions = s.fractions.map { $0 * (1 - take) }
                if edge.isLeading {
                    s.children.insert(fresh, at: 0)
                    s.fractions.insert(take, at: 0)
                } else {
                    s.children.append(fresh)
                    s.fractions.append(take)
                }
                root = .split(s)
            } else {
                let children = edge.isLeading ? [fresh, root] : [root, fresh]
                let fractions = edge.isLeading ? [take, 1 - take] : [1 - take, take]
                root = .split(DockSplit(id: newID(), axis: edge.axis, children: children, fractions: fractions))
            }
        }
        root = Self.normalised(root)
    }

    private mutating func swap(_ panel: PanelID, into target: String) {
        guard let source = group(containing: panel), let other = group(id: target)?.selected else { return }
        root = Self.mapGroups(root) { g in
            var g = g
            if g.id == source.id {
                g.panels = g.panels.map { $0 == panel ? other : $0 }
                if g.selected == panel { g.selected = other }
            } else if g.id == target {
                g.panels = g.panels.map { $0 == other ? panel : $0 }
                g.selected = panel
            }
            return g
        }
    }

    static func inserting(_ fresh: DockNode, beside target: String, _ edge: DockEdge, in node: DockNode, newID: () -> String) -> DockNode {
        switch node {
        case .group(let g):
            // Reached the target without a parent split along this axis to join.
            guard g.id == target else { return node }
            let children = edge.isLeading ? [fresh, node] : [node, fresh]
            return .split(DockSplit(id: newID(), axis: edge.axis, children: children))
        case .split(var s):
            // The target is a direct child and this split runs the same way:
            // join it as a sibling, sharing the target's space, rather than
            // nesting another split.
            if s.axis == edge.axis, let i = s.children.firstIndex(where: { $0.id == target }) {
                let half = s.fractions[i] / 2
                s.fractions[i] = half
                let at = edge.isLeading ? i : i + 1
                s.children.insert(fresh, at: at)
                s.fractions.insert(half, at: at)
                return .split(s)
            }
            s.children = s.children.map { inserting(fresh, beside: target, edge, in: $0, newID: newID) }
            return .split(s)
        }
    }

    /// The node without the panel, tidied, or nil if nothing is left.
    static func removing(_ panel: PanelID, from node: DockNode) -> DockNode? {
        switch node {
        case .group(var g):
            guard let i = g.panels.firstIndex(of: panel) else { return node }
            g.panels.remove(at: i)
            if g.panels.isEmpty { return nil }
            // The neighbour takes over, as closing a tab does in an editor.
            if g.selected == panel { g.selected = g.panels[min(i, g.panels.count - 1)] }
            return .group(g)
        case .split(var s):
            var children: [DockNode] = []
            var fractions: [Double] = []
            for (child, f) in zip(s.children, s.fractions) {
                if let kept = removing(panel, from: child) {
                    children.append(kept)
                    fractions.append(f)
                }
            }
            if children.isEmpty { return nil }
            s.children = children
            s.fractions = fractions
            return normalised(.split(s))
        }
    }

    /// No one-child splits, no split inside another along the same axis,
    /// fractions adding up to 1. Applied all the way down.
    static func normalised(_ node: DockNode) -> DockNode {
        guard case .split(var s) = node else { return node }
        var children: [DockNode] = []
        var fractions: [Double] = []
        for (child, f) in zip(s.children.map(normalised), s.fractions) {
            if case .split(let inner) = child, inner.axis == s.axis {
                // Same direction: its children become ours, scaled to its share.
                children += inner.children
                fractions += inner.fractions.map { $0 * f }
            } else {
                children.append(child)
                fractions.append(f)
            }
        }
        if children.count == 1 { return children[0] }
        s.children = children
        s.fractions = normalisedFractions(fractions)
        return .split(s)
    }

    static func normalisedFractions(_ fractions: [Double]) -> [Double] {
        let sum = fractions.reduce(0, +)
        guard sum > 0 else { return fractions.map { _ in 1 / Double(max(fractions.count, 1)) } }
        return fractions.map { $0 / sum }
    }

    static func mapGroups(_ node: DockNode, _ f: (DockGroup) -> DockGroup) -> DockNode {
        switch node {
        case .group(let g): .group(f(g))
        case .split(var s):
            {
                s.children = s.children.map { mapGroups($0, f) }
                return .split(s)
            }()
        }
    }

    static func mapSplits(_ node: DockNode, _ f: (DockSplit) -> DockSplit) -> DockNode {
        switch node {
        case .group: node
        case .split(let s):
            {
                var s = f(s)
                s.children = s.children.map { mapSplits($0, f) }
                return .split(s)
            }()
        }
    }

    static func groups(in node: DockNode) -> [DockGroup] {
        switch node {
        case .group(let g): [g]
        case .split(let s): s.children.flatMap(groups(in:))
        }
    }

    static func panels(in node: DockNode) -> [PanelID] {
        groups(in: node).flatMap(\.panels)
    }
}
