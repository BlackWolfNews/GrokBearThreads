import AppKit
import QuartzCore

/// The working line's bear, alive: it pops up when a turn starts, gives a
/// little wave every few seconds, breathes, and blinks now and then. Mike
/// watches this line while a turn runs, so the wave comes in bursts rather
/// than flapping non-stop next to the text he's reading.
///
/// It's the waving pose from Bear.swift cut into layers, so all of the
/// movement is Core Animation and carries on while the main thread is busy
/// (AGENTS.md, "Animations"). Under Reduce Motion it's the still pose.
final class WavingBearView: NSView {
    /// The line colour. A plain layer can't be a template image, so this
    /// is resolved by hand whenever the appearance changes.
    var tint: NSColor = .secondaryLabelColor {
        didSet { applyTint() }
    }

    /// One full run of each movement. The lengths don't divide evenly into
    /// each other, so the wave, breath and blink never settle into one
    /// obvious repeating loop.
    enum Timing {
        static let wave: CFTimeInterval = 6
        static let breath: CFTimeInterval = 3.4
        static let blink: CFTimeInterval = 7.3
        /// The paw's swing in degrees at seconds into the wave. Starts and
        /// ends at rest, so the still pose and the repeat both line up, and
        /// only ever swings outward: at rest the paw is already against the
        /// ear, so going the other way runs it through the head.
        static let paw: [(at: Double, degrees: Double)] = [
            (0, 0), (0.16, 14), (0.38, 3), (0.6, 14), (0.82, 3), (1.04, 10), (1.3, 0), (wave, 0),
        ]
    }

    /// Holds the grid's y-down coordinates, as the static pose has.
    private let stage = CALayer()
    /// The pop on arrival. A layer of its own so it can't fight the breath.
    private let arrival = CALayer()
    /// Everything that sways and breathes.
    private let figure = CALayer()
    private let ears = CAShapeLayer()
    private let earMask = CAShapeLayer()
    private let head = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let nose = CAShapeLayer()
    /// The arm, pad and toes, swinging about the shoulder.
    private let paw = CALayer()
    private let arm = CAShapeLayer()
    private let pad = CAShapeLayer()
    private let toes = CAShapeLayer()

    private var builtSide: CGFloat = 0

    /// Whether any of the looping movement is on.
    var isAnimating: Bool { paw.animation(forKey: Key.paw) != nil }

    private enum Key {
        static let paw = "bear.paw"
        static let sway = "bear.sway"
        static let breath = "bear.breath"
        static let blink = "bear.blink"
        static let arrival = "bear.arrival"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The paw swings a little past the grid's right edge.
        clipsToBounds = false
        stage.isGeometryFlipped = true
        layer?.addSublayer(stage)
        stage.addSublayer(arrival)
        arrival.addSublayer(figure)
        ears.mask = earMask
        for part in [ears, head, eyes, nose] { figure.addSublayer(part) }
        figure.addSublayer(paw)
        for part in [arm, pad, toes] { paw.addSublayer(part) }
        setAccessibilityRole(.image)
        setAccessibilityLabel(Bear.description(.wave))
        applyTint()
        // init(frame:) doesn't go through setFrameSize.
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    // MARK: Moving

    /// Starts the movement, if it isn't going already. `fresh` adds the
    /// pop up from nothing, for a turn that's only just begun.
    func start(fresh: Bool, reduceMotion: Bool? = nil) {
        guard !(reduceMotion ?? Juice.reduceMotion), !isAnimating else { return }
        paw.add(Self.loop("transform.rotation.z", length: Timing.wave,
                          keys: Timing.paw.map { ($0.at, $0.degrees * .pi / 180) }), forKey: Key.paw)
        // The whole bear leans with the wave, a fraction as far.
        figure.add(Self.loop("transform.rotation.z", length: Timing.wave,
                             keys: Timing.paw.map { ($0.at, -$0.degrees * 0.16 * .pi / 180) }), forKey: Key.sway)
        figure.add(Self.loop("transform.scale", length: Timing.breath,
                             keys: [(0, 1), (Timing.breath / 2, 1.03), (Timing.breath, 1)]), forKey: Key.breath)
        // One blink partway through, then a double one before it repeats.
        eyes.add(Self.loop("transform.scale.y", length: Timing.blink, keys: [
            (0, 1), (3, 1), (3.06, 0.12), (3.14, 1),
            (6.7, 1), (6.76, 0.12), (6.84, 1), (6.9, 0.12), (6.98, 1), (Timing.blink, 1),
        ]), forKey: Key.blink)
        if fresh {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.4
            pop.toValue = 1
            pop.mass = 0.6
            pop.stiffness = 240
            pop.damping = 11
            pop.duration = pop.settlingDuration
            arrival.add(pop, forKey: Key.arrival)
        }
    }

    func stop() {
        paw.removeAnimation(forKey: Key.paw)
        figure.removeAnimation(forKey: Key.sway)
        figure.removeAnimation(forKey: Key.breath)
        eyes.removeAnimation(forKey: Key.blink)
        arrival.removeAnimation(forKey: Key.arrival)
    }

    /// A forever-repeating track from (seconds, value) pairs. Thirty frames
    /// a second is plenty at this size, and this runs for whole turns, so
    /// it shouldn't keep the display at 120.
    private static func loop(_ keyPath: String, length: CFTimeInterval, keys: [(Double, Double)]) -> CAKeyframeAnimation {
        let track = CAKeyframeAnimation(keyPath: keyPath)
        track.values = keys.map(\.1)
        track.keyTimes = keys.map { NSNumber(value: $0.0 / length) }
        track.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        track.calculationMode = .cubic
        track.duration = length
        track.repeatCount = .infinity
        // Keeps its place through a layer leaving and rejoining the tree;
        // stop() is what ends it.
        track.isRemovedOnCompletion = false
        track.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return track
    }

    // MARK: Drawing

    private func applyTint() {
        var ink: CGColor = tint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = self.tint.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in [ears, head, arm, pad] {
            line.strokeColor = ink
            line.fillColor = nil
        }
        for solid in [eyes, nose, toes] {
            solid.fillColor = ink
            solid.strokeColor = nil
        }
        CATransaction.commit()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [stage, arrival, figure, paw, ears, earMask, head, eyes, nose, arm, pad, toes] {
            part.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// Lays the parts out for this size. Paths are made at the real size,
    /// not scaled afterwards, so the lines stay sharp at any zoom.
    private func rebuild() {
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stage.frame = bounds
        guard side > 0, side != builtSide else { return }
        builtSide = side
        let unit = side / 24
        let scale = CGAffineTransform(scaleX: unit, y: unit)
        var transform = scale
        let square = CGRect(x: 0, y: 0, width: side, height: side)

        func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
            CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        /// Pins a layer so it turns and scales about this spot on the grid.
        func pin(_ part: CALayer, about point: CGPoint) {
            part.bounds = square
            part.anchorPoint = CGPoint(x: point.x / 24, y: point.y / 24)
            part.position = CGPoint(x: point.x * unit, y: point.y * unit)
        }

        let c = Bear.Wave.headCentre, r = Bear.Wave.headRadius
        // These match drawHead in Bear.swift; BearTests checks the still
        // layers against the still pose.
        let eyeY = c.y - r * 0.12
        let feet = CGPoint(x: c.x, y: c.y + r)

        pin(arrival, about: feet)
        pin(figure, about: feet)
        pin(eyes, about: CGPoint(x: c.x, y: eyeY))
        pin(paw, about: Bear.Wave.shoulder)
        for part in [ears, head, nose, arm, pad, toes] { part.frame = square }

        head.path = CGPath(ellipseIn: circle(c, r), transform: &transform)

        let earPath = CGMutablePath()
        for sign in [-1.0, 1.0] {
            let ear = CGPoint(x: c.x + sign * r * 0.72, y: c.y - r * 0.72)
            earPath.addEllipse(in: circle(ear, Bear.Wave.earRadius), transform: scale)
        }
        ears.path = earPath
        // Ears show only outside the head, so the outlines don't cross.
        let outside = CGMutablePath()
        outside.addRect(square.insetBy(dx: -side, dy: -side))
        outside.addEllipse(in: circle(c, r), transform: scale)
        earMask.frame = square
        earMask.path = outside
        earMask.fillRule = .evenOdd
        earMask.fillColor = NSColor.black.cgColor

        let eyePath = CGMutablePath()
        for sign in [-1.0, 1.0] {
            eyePath.addEllipse(in: circle(CGPoint(x: c.x + sign * r * 0.4, y: eyeY), r * 0.14), transform: scale)
        }
        eyes.path = eyePath

        let noseW = r * 0.34, noseH = r * 0.24
        nose.path = CGPath(ellipseIn: CGRect(x: c.x - noseW / 2, y: c.y + r * 0.3 - noseH / 2, width: noseW, height: noseH),
                           transform: &transform)

        let armPath = CGMutablePath()
        armPath.move(to: Bear.Wave.shoulder, transform: scale)
        armPath.addCurve(to: Bear.Wave.armEnd, control1: Bear.Wave.armControl1, control2: Bear.Wave.armControl2, transform: scale)
        arm.path = armPath
        arm.lineCap = .round

        pad.path = CGPath(ellipseIn: circle(Bear.Wave.paw, Bear.Wave.pawRadius), transform: &transform)

        let toePath = CGMutablePath()
        for toe in Bear.Wave.toes { toePath.addEllipse(in: circle(toe, Bear.Wave.toeRadius), transform: scale) }
        toes.path = toePath

        for line in [ears, head, arm, pad] { line.lineWidth = 1.6 * unit }
        applyScale()
    }

    /// The layers as they stand, for BearTests to compare with the pose.
    func renderStill(in context: CGContext) {
        layer?.render(in: context)
    }

    #if DEBUG
    /// Draws the bear as it looks `seconds` into its loops, from the real
    /// tracks, for BearTests' BEAR_FRAMES. Core Animation can't be sampled
    /// to a bitmap, least of all with the screen locked.
    func renderFrame(at seconds: Double, in context: CGContext) {
        let moved: [(CALayer, String)] = [(paw, Key.paw), (figure, Key.sway), (figure, Key.breath), (eyes, Key.blink)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (part, key) in moved {
            guard let track = part.animation(forKey: key) as? CAKeyframeAnimation,
                  let values = track.values as? [Double], let times = track.keyTimes?.map(\.doubleValue),
                  let keyPath = track.keyPath else { continue }
            let t = seconds.truncatingRemainder(dividingBy: track.duration) / track.duration
            let i = max(0, (times.lastIndex { $0 <= t } ?? 0))
            let j = min(i + 1, values.count - 1)
            let span = max(0.000_001, times[j] - times[i])
            part.setValue(values[i] + (values[j] - values[i]) * min(1, (t - times[i]) / span), forKeyPath: keyPath)
        }
        CATransaction.commit()
        layer?.render(in: context)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [paw, figure, eyes] { part.setAffineTransform(.identity) }
        CATransaction.commit()
    }
    #endif
}
