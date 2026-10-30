import AppKit
import SwiftUI
import ThreadbearCore

/// The open thread's panel dropping into the Archived heading when it's
/// archived. Mike found the panel just flicking to the next thread flat
/// beside the sidebar's sliding row, and picked this, "D2 · Drop", from
/// mockups (30 Oct; docs/archive-transition-design). It falls first and
/// then curves across into the heading's archive box, shrinking and
/// tipping slightly, like a sheet dropped into a drawer. The box bounces
/// and the count rolls on as it lands (`AppModel.flyingToArchive`), and the
/// next thread fades in underneath.
///
/// The transcript is one table that the next thread reuses straight away,
/// so what flies is a picture of it, in a see-through window over the main
/// one (above the sidebar, and nothing in it takes clicks). The heading is
/// found each frame, as it moves up while the archived row closes up. With
/// the heading out of sight (a long inbox, a lazy list that hasn't drawn
/// it) the picture falls off the bottom of the list instead; with no list
/// (another sidebar view) or under Reduce Motion it just fades.
@MainActor
enum ArchiveFlight {
    /// The Archived heading's box and the inbox list, while they're drawn
    /// (`FlightMarker`).
    fileprivate(set) static weak var archiveBox: NSView?
    fileprivate(set) static weak var inboxList: NSView?

    static let duration: Double = 0.44
    /// How long the last flight's picture took, for the perf run.
    private(set) static var lastPictureMs = 0.0

    /// Starts a flight from `view` as it looks now, and fades `view` back
    /// in for the thread that replaces it. Calls `landed` at the end.
    /// False, with nothing started, when there's nothing to picture.
    static func launch(from view: NSView, landed: @escaping @MainActor () -> Void) -> Bool {
        let pictureStart = CACurrentMediaTime()
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1, view.bounds.height > 1,
              let picture = picture(of: view) else { return false }
        lastPictureMs = (CACurrentMediaTime() - pictureStart) * 1000
        let overlay = Overlay(over: window)
        let card = CALayer()
        card.contents = picture
        card.contentsScale = window.backingScaleFactor
        card.contentsGravity = .resize
        card.masksToBounds = true
        // The pane's own background, which the table doesn't draw.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        card.frame = view.convert(view.bounds, to: nil)
        overlay.layer.addSublayer(card)

        // The next thread comes in under it once it's on its way.
        view.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (Juice.reduceMotion ? 0.05 : 0.2)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Juice.reduceMotion ? 0.15 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }

        let flight = Flight(card: card, overlay: overlay, window: window, landed: landed)
        flight.start(from: view)
        return true
    }

    /// The view as drawn, transparent where it draws nothing.
    private static func picture(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Where the card is headed, in window coordinates, and whether that's
    /// the heading itself or just the bottom of the list.
    fileprivate static func target(in window: NSWindow) -> (point: CGPoint, onHeading: Bool)? {
        if let box = archiveBox, box.window === window, !box.visibleRect.isEmpty {
            let frame = box.convert(box.bounds, to: nil)
            return (CGPoint(x: frame.midX, y: frame.midY), true)
        }
        if let list = inboxList, list.window === window, !list.visibleRect.isEmpty {
            let frame = list.convert(list.visibleRect, to: nil)
            // Where the heading's box would be, at the list's bottom edge.
            return (CGPoint(x: frame.minX + SidebarMetrics.leading + zoomed(7), y: frame.minY), false)
        }
        return nil
    }
}

/// One card's flight, run off the window's display link so it can follow
/// the heading as the list moves.
@MainActor
private final class Flight: NSObject {
    let card: CALayer
    let overlay: Overlay
    weak var window: NSWindow?
    let landed: @MainActor () -> Void
    private var start: CGPoint = .zero
    private var began: CFTimeInterval = 0
    private var link: CADisplayLink?
    /// Kept alive by the display link while it runs; this is its retain.
    private var me: Flight?
    private var fadeOnly = false

    init(card: CALayer, overlay: Overlay, window: NSWindow, landed: @escaping @MainActor () -> Void) {
        self.card = card
        self.overlay = overlay
        self.window = window
        self.landed = landed
    }

    func start(from view: NSView) {
        start = card.position
        fadeOnly = Juice.reduceMotion || window.flatMap { ArchiveFlight.target(in: $0) } == nil
        began = CACurrentMediaTime()
        me = self
        link = view.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func step() {
        let t = min(1, (CACurrentMediaTime() - began) / (fadeOnly ? 0.18 : ArchiveFlight.duration))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fadeOnly {
            card.opacity = Float(1 - t)
            if !Juice.reduceMotion { card.transform = CATransform3DMakeScale(1 - 0.04 * t, 1 - 0.04 * t, 1) }
        } else if let window, let target = ArchiveFlight.target(in: window) {
            let path = ArchiveFlightPath(start: start, end: target.point, swing: zoomed(40), onHeading: target.onHeading)
            let frame = path.frame(at: ArchiveFlightPath.progress(atTime: t))
            card.position = frame.position
            card.transform = CATransform3DRotate(CATransform3DMakeScale(frame.scale, frame.scale, 1), frame.tilt, 0, 0, 1)
            card.cornerRadius = frame.cornerRadius
            card.opacity = Float(frame.opacity)
        }
        CATransaction.commit()
        if t >= 1 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        overlay.close()
        landed()
        me = nil
    }
}

/// A see-through, click-through window exactly over `window`, for the
/// card to fly in above the sidebar and the panel alike.
@MainActor
private final class Overlay {
    let panel: NSWindow
    let layer: CALayer
    private weak var parent: NSWindow?

    init(over window: NSWindow) {
        panel = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        host.wantsLayer = true
        panel.contentView = host
        layer = host.layer!
        parent = window
        window.addChildWindow(panel, ordered: .above)
    }

    func close() {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Marks where an archive flight can land: an invisible view whose frame
/// `ArchiveFlight` reads each frame of a flight.
struct FlightMarker: NSViewRepresentable {
    enum Kind { case archiveBox, inboxList }
    let kind: Kind

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        register(view)
    }

    private func register(_ view: NSView) {
        switch kind {
        case .archiveBox: ArchiveFlight.archiveBox = view
        case .inboxList: ArchiveFlight.inboxList = view
        }
    }
}

extension EnvironmentValues {
    /// Set on the Archived heading only: how many flights have landed in
    /// it, so its box bounces at each, and where the flights aim.
    @Entry var archiveLandings: Int? = nil
}
