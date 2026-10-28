import AppKit
import Observation
import SwiftUI

/// What the compass in the middle of a group offers.
public enum CompassItem: Hashable, Sendable {
    case tab
    case split(DockEdge)
    case swap

    var label: String {
        switch self {
        case .tab: "Add as a tab"
        case .swap: "Swap places"
        case .split(.left): "Dock on the left"
        case .split(.right): "Dock on the right"
        case .split(.top): "Dock above"
        case .split(.bottom): "Dock below"
        }
    }
}

/// Where the pointer is pointing while a panel is being dragged.
struct DropTarget: Equatable {
    /// Nil over the compass's gaps or a drop that would go nowhere.
    var drop: DockDrop?
    /// The space the panel would take, in the dock's coordinates.
    var preview: CGRect
    /// The compass, while the pointer is over the middle of a group.
    var compass: CompassState?
}

struct CompassState: Equatable {
    var group: String
    var center: CGPoint
    var hovered: CompassItem?
    /// Items that would do nothing here (the panel's own group), drawn dimmed.
    var disabled: Set<CompassItem>
}

struct DragState: Equatable {
    var panel: PanelID
    var sourceGroup: String
    /// The group's frame when the drag started.
    var sourceFrame: CGRect
    /// Where in the panel it was picked up, 0...1 each way, so that point
    /// stays under the pointer as it shrinks.
    var grab: CGPoint
    var location: CGPoint
    var lifted = false
    var target: DropTarget?
}

/// The ghost flying to where the panel landed (or back home), after the drop.
struct Landing: Equatable {
    var panel: PanelID
    var sourceSize: CGSize
    var to: CGRect
    var done = false
}

/// The layout and everything about a drag in progress. One per dock.
@MainActor
@Observable
public final class DockController {
    public var layout: DockLayout {
        didSet { if layout != oldValue { onChange?(layout) } }
    }
    /// Called when the layout changes, to save it.
    @ObservationIgnored public var onChange: ((DockLayout) -> Void)?

    var drag: DragState?
    var landing: Landing?
    /// Each group's frame in the dock's coordinates, from the views.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero
    /// Set by Escape until the gesture that was cancelled ends.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escapeMonitor: Any?

    // Feel. Tuned by eye in the demo.
    /// How far in from a group's side, as a share of its size, counts as that side.
    static let edgeBand: CGFloat = 0.28
    /// Within this of the window's side, the drop spans the whole side.
    static let windowBand: CGFloat = 22
    /// The ghost's width once lifted, within limits.
    static let ghostWidth: CGFloat = 240
    static let lift = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let track = Animation.snappy(duration: 0.16)

    public init(layout: DockLayout) {
        self.layout = layout
    }

    // MARK: Dragging

    /// From a drag gesture on a panel's body or its tab. Locations are in the
    /// dock's coordinate space.
    public func dragChanged(panel: PanelID, start: CGPoint, location: CGPoint) {
        // Escape put it back; the gesture keeps reporting until the button's up.
        if cancelled { return }
        if drag == nil {
            guard landing == nil, let group = layout.group(containing: panel), let frame = frames[group.id] else { return }
            // A tab that isn't showing comes to the front as it's picked up.
            if group.selected != panel { layout.select(panel) }
            drag = DragState(
                panel: panel,
                sourceGroup: group.id,
                sourceFrame: frame,
                grab: CGPoint(x: (start.x - frame.minX) / max(frame.width, 1), y: (start.y - frame.minY) / max(frame.height, 1)),
                location: location
            )
            NSCursor.closedHand.push()
            watchForEscape()
            if ProcessInfo.processInfo.environment["BEARDOCK_LOG"] != nil { print("lift \(panel) from \(start)") }
            withAnimation(Self.lift) { drag?.lifted = true }
        }
        drag?.location = location
        let target = target(for: panel, at: location)
        if target != drag?.target {
            withAnimation(Self.track) { drag?.target = target }
        }
    }

    public func dragEnded() {
        if cancelled {
            cancelled = false
            return
        }
        guard let d = drag else { return }
        finish(d, drop: d.target?.drop)
    }

    /// Escape, mid-drag: the panel flies home and the rest of the gesture is ignored.
    public func cancelDrag() {
        guard let d = drag else { return }
        cancelled = true
        finish(d, drop: nil)
    }

    private func finish(_ d: DragState, drop: DockDrop?) {
        NSCursor.pop()
        stopWatchingForEscape()
        let size = d.sourceFrame.size
        if let drop, let to = d.target?.preview {
            landing = Landing(panel: d.panel, sourceSize: size, to: to)
            withAnimation(Self.settle) {
                drag = nil
                layout.move(d.panel, drop)
                landing?.done = true
            }
        } else {
            // Nowhere to go, or cancelled: fly home.
            landing = Landing(panel: d.panel, sourceSize: size, to: frames[d.sourceGroup] ?? d.sourceFrame)
            withAnimation(Self.settle) {
                drag = nil
                landing?.done = true
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeOut(duration: 0.12)) { self.landing = nil }
        }
    }

    /// A key monitor only while a drag's in progress, so Escape reaches the
    /// dock whatever has focus, and is swallowed rather than also closing a
    /// sheet or clearing a field.
    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            MainActor.assumeIsolated { self.cancelDrag() }
            return nil
        }
    }

    private func stopWatchingForEscape() {
        if let m = escapeMonitor { NSEvent.removeMonitor(m) }
        escapeMonitor = nil
    }

    /// A panel's group's frame in the dock, for tests and the demo's
    /// frozen drags.
    public func frame(of panel: PanelID) -> CGRect? {
        layout.group(containing: panel).flatMap { frames[$0.id] }
    }

    // MARK: Other changes

    public func close(_ panel: PanelID) {
        withAnimation(Self.settle) { layout.close(panel) }
    }

    public func select(_ panel: PanelID) {
        layout.select(panel)
    }

    /// Opens a panel that isn't in the layout, along the right of the window.
    public func open(_ panel: PanelID, _ drop: DockDrop = .window(.right)) {
        withAnimation(Self.settle) { layout.add(panel, drop) }
    }

    public func setLayout(_ layout: DockLayout) {
        withAnimation(Self.settle) { self.layout = layout }
    }

    // MARK: Hit testing

    func target(for panel: PanelID, at p: CGPoint) -> DropTarget? {
        // The window's own sides first: a thin strip all along each.
        if bounds.width > 0, let edge = windowEdge(at: p), layout.canDrop(panel, .window(edge)) {
            return DropTarget(drop: .window(edge), preview: Self.slice(bounds, edge, 0.25))
        }
        guard let group = layout.groups.first(where: { frames[$0.id]?.contains(p) == true }),
              let frame = frames[group.id] else { return nil }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let items = Self.compassItems(center: center)
        let compassArea = items.reduce(CGRect.null) { $0.union($1.1) }.insetBy(dx: -14, dy: -14)

        // The sides of the group, unless the pointer is on the compass.
        if !compassArea.contains(p) {
            let fx = (p.x - frame.minX) / frame.width, fy = (p.y - frame.minY) / frame.height
            let sides: [(DockEdge, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
            let (edge, distance) = sides.min { $0.1 < $1.1 }!
            if distance < Self.edgeBand {
                let drop = DockDrop.edge(group: group.id, edge)
                return DropTarget(drop: layout.canDrop(panel, drop) ? drop : nil, preview: Self.slice(frame, edge, 0.5))
            }
        }

        // The middle: the compass, and whatever it's on (a tab by default).
        let disabled = Set(items.map(\.0).filter { !layout.canDrop(panel, Self.drop(for: $0, group: group.id)) })
        let hovered = items.first { $0.1.contains(p) }?.0
        let item = hovered ?? .tab
        let drop = disabled.contains(item) ? nil : Self.drop(for: item, group: group.id)
        let preview: CGRect = switch item {
        case .split(let edge): Self.slice(frame, edge, 0.5)
        case .tab, .swap: frame
        }
        return DropTarget(
            drop: drop,
            preview: preview,
            compass: CompassState(group: group.id, center: center, hovered: hovered, disabled: disabled)
        )
    }

    private func windowEdge(at p: CGPoint) -> DockEdge? {
        let b = Self.windowBand
        if p.x - bounds.minX < b { return .left }
        if bounds.maxX - p.x < b { return .right }
        if p.y - bounds.minY < b { return .top }
        if bounds.maxY - p.y < b { return .bottom }
        return nil
    }

    static func drop(for item: CompassItem, group: String) -> DockDrop {
        switch item {
        case .tab: .tab(group: group)
        case .swap: .swap(group: group)
        case .split(let edge): .edge(group: group, edge)
        }
    }

    /// The compass's buttons around a group's centre: a cross of five, and
    /// Swap under it.
    static func compassItems(center c: CGPoint) -> [(CompassItem, CGRect)] {
        let s = Compass.button, step = Compass.button + Compass.gap
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGRect {
            CGRect(x: c.x + dx * step - s / 2, y: c.y + dy * step - s / 2, width: s, height: s)
        }
        let swap = CGRect(x: c.x - Compass.swapWidth / 2, y: c.y + 2 * step - s / 2 + 6, width: Compass.swapWidth, height: Compass.swapHeight)
        return [
            (.tab, at(0, 0)),
            (.split(.top), at(0, -1)),
            (.split(.bottom), at(0, 1)),
            (.split(.left), at(-1, 0)),
            (.split(.right), at(1, 0)),
            (.swap, swap),
        ]
    }

    /// The share of a rect along one side.
    static func slice(_ r: CGRect, _ edge: DockEdge, _ share: CGFloat) -> CGRect {
        switch edge {
        case .left: CGRect(x: r.minX, y: r.minY, width: r.width * share, height: r.height)
        case .right: CGRect(x: r.maxX - r.width * share, y: r.minY, width: r.width * share, height: r.height)
        case .top: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * share)
        case .bottom: CGRect(x: r.minX, y: r.maxY - r.height * share, width: r.width, height: r.height * share)
        }
    }

    /// The ghost's rect while lifted: shrunk, with the grab point under the pointer.
    func ghostRect(for d: DragState) -> CGRect {
        let size = d.sourceFrame.size
        let scale = d.lifted ? min(0.85, max(0.3, Self.ghostWidth / max(size.width, 1))) : 1
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: d.location.x - d.grab.x * w, y: d.location.y - d.grab.y * h, width: w, height: h)
    }
}

enum Compass {
    static let button: CGFloat = 36
    static let gap: CGFloat = 6
    static let swapWidth: CGFloat = 84
    static let swapHeight: CGFloat = 26
}
