import AppKit
import QuartzCore

/// A bear in Core Animation layers, for one that moves by itself in a
/// transcript or the sidebar: the drawing comes from BearGeometry's inks, so
/// it's the same bear as the still images, and the movement carries on while
/// the main thread is busy (AGENTS.md, "Animations").
///
/// Subclasses put layers on `stage` and fill them in `layOut`, which runs
/// again for a new size, appearance or screen. Clicks go through to what's
/// behind: nothing here is a control.
class InkLayersView: NSView {
    /// The line colour. A plain layer can't be a template image, so this is
    /// resolved by hand whenever the appearance changes.
    var tint: NSColor = .secondaryLabelColor {
        didSet { redraw() }
    }

    /// Holds the grid's y-down coordinates, as the static pose has.
    let stage = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Some of what moves goes a little past the grid's edge.
        clipsToBounds = false
        stage.isGeometryFlipped = true
        layer?.addSublayer(stage)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    /// Fills the layers for this size and colour. Replaces only what's on
    /// `InkLayersView.fill`'s hosts, so animations on the hosts themselves go on.
    func layOut(side: CGFloat, drawing: Drawing) {}

    /// What a subclass needs to turn inks into layers at the current size.
    struct Drawing {
        var unit: CGFloat
        var ink: CGColor
        var screen: CGFloat
    }

    final func redraw() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        var ink = tint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = self.tint.cgColor }
        let screen = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        layOut(side: side, drawing: Drawing(unit: side / 24, ink: ink, screen: screen))
        CATransaction.commit()
    }

    /// Replaces what's in `host` with these inks.
    static func fill(_ host: CALayer, _ inks: [BearGeometry.Ink], square: CGRect, _ drawing: Drawing) {
        var scale = CGAffineTransform(scaleX: drawing.unit, y: drawing.unit)
        host.contentsScale = drawing.screen
        host.sublayers = inks.map { ink in
            let shape = CAShapeLayer()
            shape.frame = square
            shape.contentsScale = drawing.screen
            shape.path = ink.path.copy(using: &scale)
            shape.lineCap = .round
            shape.lineJoin = .round
            if let width = ink.width {
                shape.strokeColor = drawing.ink
                shape.fillColor = nil
                shape.lineWidth = width * drawing.unit
            } else {
                shape.fillColor = drawing.ink
                shape.strokeColor = nil
            }
            if let outside = ink.outside { shape.mask = mask(outside: outside, square: square, drawing) }
            return shape
        }
    }

    /// A mask that shows only what's outside a path on the grid, so outlines don't cross.
    static func mask(outside path: CGPath, square: CGRect, _ drawing: Drawing) -> CAShapeLayer {
        var scale = CGAffineTransform(scaleX: drawing.unit, y: drawing.unit)
        let everywhereElse = CGMutablePath()
        everywhereElse.addRect(square.insetBy(dx: -square.width, dy: -square.height))
        if let sized = path.copy(using: &scale) { everywhereElse.addPath(sized) }
        let mask = CAShapeLayer()
        mask.frame = square
        mask.contentsScale = drawing.screen
        mask.path = everywhereElse
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        return mask
    }

    /// Pins a layer so it turns and scales about this spot on the grid.
    static func pin(_ part: CALayer, about point: CGPoint, square: CGRect) {
        part.bounds = square
        part.anchorPoint = CGPoint(x: point.x / 24, y: point.y / 24)
        part.position = CGPoint(x: point.x * square.width / 24, y: point.y * square.height / 24)
    }

    /// A track from (seconds, value) pairs. Thirty frames a second is plenty
    /// at this size, and some of these run for as long as they're on screen.
    static func track(_ keyPath: String, length: CFTimeInterval, begin: CFTimeInterval = 0, repeats: Bool = false, keys: [(Double, Double)]) -> CAKeyframeAnimation {
        let track = CAKeyframeAnimation(keyPath: keyPath)
        track.values = keys.map(\.1)
        track.keyTimes = keys.map { NSNumber(value: $0.0 / length) }
        track.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(1, keys.count - 1))
        track.duration = length
        track.beginTime = begin
        track.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        if repeats {
            track.repeatCount = .infinity
            // Keeps its place through a layer leaving and rejoining the tree.
            track.isRemovedOnCompletion = false
        }
        return track
    }
}

/// The bedtime bear under an empty Inbox: asleep, breathing slowly, with its
/// two Zs drifting up and fading. Only here and only at night, so a slow
/// loop is all the movement there is. Under Reduce Motion it's the still pose.
final class SleepingBearView: InkLayersView {
    enum Timing {
        static let breath: CFTimeInterval = 4.4
        static let drift: CFTimeInterval = 3
        /// The big Z comes a beat after the small one.
        static let secondZ: CFTimeInterval = 0.7
        /// Into the drift in seconds: how far up it's gone, on the grid, and
        /// how much of it shows.
        static let zKeys: [(at: Double, up: Double, shown: Double)] = [
            (0, -0.6, 0), (0.75, 0, 1), (2.1, 1.4, 0.85), (drift, 2.4, 0),
        ]
    }

    /// Everything that breathes.
    private let figure = CALayer()
    private let head = CALayer()
    private let zs = [CALayer(), CALayer()]

    var isDrifting: Bool { zs[0].animation(forKey: "bear.drift") != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stage.addSublayer(figure)
        figure.addSublayer(head)
        zs.forEach(stage.addSublayer)
        setAccessibilityLabel(Bear.description(.sleep))
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    func start(reduceMotion: Bool? = nil) {
        guard !(reduceMotion ?? Juice.reduceMotion), !isDrifting else { return }
        let length = Timing.breath
        figure.add(Self.track("transform.scale.x", length: length, repeats: true, keys: [(0, 1), (length / 2, 1.025), (length, 1)]), forKey: "bear.breathX")
        figure.add(Self.track("transform.scale.y", length: length, repeats: true, keys: [(0, 1), (length / 2, 1.035), (length, 1)]), forKey: "bear.breathY")
        let now = CACurrentMediaTime()
        for (index, z) in zs.enumerated() {
            let begin = now + Double(index) * Timing.secondZ
            let keys = Timing.zKeys
            let group = CAAnimationGroup()
            group.animations = [
                Self.track("opacity", length: Timing.drift, keys: keys.map { ($0.at, $0.shown) }),
                Self.track("transform.translation.y", length: Timing.drift, keys: keys.map { ($0.at, -$0.up * Double(unit)) }),
            ]
            group.duration = Timing.drift
            group.beginTime = begin
            group.repeatCount = .infinity
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            group.isRemovedOnCompletion = false
            // Hidden until its first drift, for the one that starts late.
            group.fillMode = .backwards
            z.add(group, forKey: "bear.drift")
        }
    }

    func stop() {
        figure.removeAllAnimations()
        zs.forEach { $0.removeAllAnimations() }
    }

    private var unit: CGFloat { min(bounds.width, bounds.height) / 24 }

    override func layOut(side: CGFloat, drawing: Drawing) {
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        Self.pin(figure, about: BearGeometry.sleepingFeet, square: square)
        head.frame = square
        Self.fill(head, BearGeometry.sleepingHead(small: side < BearGeometry.smallSide), square: square, drawing)
        let wasDrifting = isDrifting
        for (z, path) in zip(zs, BearGeometry.sleepZs) {
            z.frame = square
            Self.fill(z, [BearGeometry.Ink(path: path, width: BearGeometry.Face.shutWidth)], square: square, drawing)
        }
        // Drifts are in points, so a new size wants them worked out again.
        if wasDrifting { stop(); start() }
    }
}
