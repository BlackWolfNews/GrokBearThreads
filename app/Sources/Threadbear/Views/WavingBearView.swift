import AppKit
import QuartzCore

/// The working line's bear, alive: it pops up when a turn starts, gives a
/// little wave every few seconds, breathes, and blinks now and then. Mike
/// watches this line while a turn runs, so the wave comes in bursts rather
/// than flapping non-stop next to the text he's reading.
///
/// It's the waving pose from BearGeometry cut into layers, so all of the
/// movement is Core Animation and carries on while the main thread is busy
/// (AGENTS.md, "Animations"). Under Reduce Motion it's the still pose.
///
/// A secret, with no tip to give it away: rest the pointer on it and it waves
/// back straight away, and click it and it hops.
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
        /// only ever swings outward: at rest the paw is already close to the
        /// ear, so going the other way runs it into the ear.
        static let paw: [(at: Double, degrees: Double)] = [
            (0, 0), (0.16, 14), (0.38, 3), (0.6, 14), (0.82, 3), (1.04, 10), (1.3, 0), (wave, 0),
        ]
        /// How long the paw is up in each wave.
        static let burst: CFTimeInterval = 1.3
        /// Wiggling the pointer over it shouldn't make it flap.
        static let waveBackGap: CFTimeInterval = 3
        /// The hop on a click, as the fraction of it each point comes at: a
        /// squash, up on its toes, a squash on landing. `up` is on the grid.
        static let hop: CFTimeInterval = 0.42
        static let hopKeys: [(at: Double, up: Double, x: Double, y: Double)] = [
            (0, 0, 1, 1), (0.15, 0, 1.08, 0.9), (0.5, 9, 0.96, 1.05), (0.85, 0, 1.08, 0.92), (1, 0, 1, 1),
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
    /// The eye that blinks. The other one's a button, and buttons don't.
    private let eyes = CAShapeLayer()
    private let buttonRing = CAShapeLayer()
    private let buttonPip = CAShapeLayer()
    private let stitch = CAShapeLayer()
    private let nose = CAShapeLayer()
    private let mouth = CAShapeLayer()
    /// Shows the arm only outside the head, so it hugs it as it swings. It
    /// doesn't turn itself, or the head's shape would turn with the arm.
    private let armClip = CALayer()
    private let armMask = CAShapeLayer()
    /// The arm and pad, swinging about the shoulder.
    private let paw = CALayer()
    private let arm = CAShapeLayer()
    private let pad = CAShapeLayer()

    private var builtSide: CGFloat = 0
    /// Between start and stop: the pointer can't wake a finished line's bear.
    private var live = false
    /// When the current wave's loop began, to tell whether the paw's up.
    private var waveBegan: CFTimeInterval = 0
    private var lastWaveBack = -CFTimeInterval.infinity
    private var lastHop = -CFTimeInterval.infinity
    private var hoverArea: NSTrackingArea?

    /// Whether any of the looping movement is on.
    var isAnimating: Bool { paw.animation(forKey: Key.paw) != nil }

    private enum Key {
        static let paw = "bear.paw"
        static let sway = "bear.sway"
        static let breath = "bear.breath"
        static let blink = "bear.blink"
        static let arrival = "bear.arrival"
        static let wink = "bear.wink"
        static let hop = "bear.hop"
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
        armClip.mask = armMask
        figure.addSublayer(armClip)
        armClip.addSublayer(paw)
        for part in [arm, pad] { paw.addSublayer(part) }
        for part in [ears, head, eyes, buttonRing, buttonPip, stitch, nose, mouth] { figure.addSublayer(part) }
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
        live = true
        guard !(reduceMotion ?? Juice.reduceMotion), !isAnimating else { return }
        addWave(at: CACurrentMediaTime())
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
        live = false
        paw.removeAnimation(forKey: Key.paw)
        figure.removeAnimation(forKey: Key.sway)
        figure.removeAnimation(forKey: Key.breath)
        eyes.removeAnimation(forKey: Key.blink)
        arrival.removeAnimation(forKey: Key.arrival)
        arrival.removeAnimation(forKey: Key.hop)
        eyes.removeAnimation(forKey: Key.wink)
    }

    /// Puts on the wave's two tracks, the burst starting at `time`. Adding
    /// them again replaces the ones running, which moves the bear's whole
    /// rhythm along, so the next burst comes a full loop after this one.
    private func addWave(at time: CFTimeInterval) {
        waveBegan = time
        paw.add(Self.loop("transform.rotation.z", length: Timing.wave, begin: time,
                          keys: Timing.paw.map { ($0.at, $0.degrees * .pi / 180) }), forKey: Key.paw)
        // The whole bear leans with the wave, a fraction as far.
        figure.add(Self.loop("transform.rotation.z", length: Timing.wave, begin: time,
                             keys: Timing.paw.map { ($0.at, -$0.degrees * 0.16 * .pi / 180) }), forKey: Key.sway)
    }

    /// Whether the paw is up now. Starting a wave then would snap it down.
    private func isMidWave(at now: CFTimeInterval) -> Bool {
        (now - waveBegan).truncatingRemainder(dividingBy: Timing.wave) < Timing.burst
    }

    private func wink(at now: CFTimeInterval) {
        let wink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        wink.values = [1, 0.12, 1]
        wink.keyTimes = [0, 0.43, 1]
        wink.duration = 0.14
        wink.beginTime = now
        eyes.add(wink, forKey: Key.wink)
    }

    /// The pointer came to rest on the bear: it blinks and waves straight
    /// away, unless it's waving already or did only just now. Under Reduce
    /// Motion it's only the blink. Says whether it noticed, for BearTests.
    @discardableResult
    func waveBack(at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard live, now - lastWaveBack >= Timing.waveBackGap else { return false }
        lastWaveBack = now
        wink(at: now)
        if isAnimating, !isMidWave(at: now) { addWave(at: now) }
        return true
    }

    /// A click: a hop with a squash at each end, and a wave once it's down.
    /// Under Reduce Motion it's a blink. A click while it's in the air
    /// doesn't start it again, or it would jump back to the ground.
    @discardableResult
    func hop(at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard live, now - lastHop >= Timing.hop else { return false }
        lastHop = now
        guard isAnimating else {
            wink(at: now)
            return true
        }
        let unit = builtSide / 24
        let track = CAKeyframeAnimation(keyPath: "transform")
        // Up is minus: the stage is flipped, and so y runs down as on the grid.
        track.values = Timing.hopKeys.map { key in
            NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(0, -key.up * unit, 0), key.x, key.y, 1))
        }
        track.keyTimes = Timing.hopKeys.map { NSNumber(value: $0.at) }
        track.timingFunction = CAMediaTimingFunction(name: .easeOut)
        track.duration = Timing.hop
        track.beginTime = now
        arrival.add(track, forKey: Key.hop)
        if !isMidWave(at: now), !isMidWave(at: now + Timing.hop) { addWave(at: now + Timing.hop) }
        return true
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        // Always, not only in the key window: it's a bear, seeing a pointer
        // go past it. It costs one track restart at most every few seconds.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { waveBack() }

    // Not passed on to the row: this click is only for the bear.
    override func mouseDown(with event: NSEvent) { hop() }

    // A click counts while Threadbear isn't the app in front, like the row's.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A forever-repeating track from (seconds, value) pairs. Thirty frames
    /// a second is plenty at this size, and this runs for whole turns, so
    /// it shouldn't keep the display at 120.
    private static func loop(_ keyPath: String, length: CFTimeInterval, begin: CFTimeInterval = 0, keys: [(Double, Double)]) -> CAKeyframeAnimation {
        let track = CAKeyframeAnimation(keyPath: keyPath)
        track.values = keys.map(\.1)
        track.keyTimes = keys.map { NSNumber(value: $0.0 / length) }
        track.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        track.calculationMode = .cubic
        track.duration = length
        track.beginTime = begin
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
        for line in [ears, head, arm, buttonRing, stitch, mouth] {
            line.strokeColor = ink
            line.fillColor = nil
        }
        for solid in [eyes, buttonPip, nose, pad] {
            solid.fillColor = ink
            solid.strokeColor = nil
        }
        CATransaction.commit()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [stage, arrival, figure, armClip, armMask, paw, ears, earMask, head, eyes, buttonRing, buttonPip, stitch, nose, mouth, arm, pad] {
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
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        /// A path from the grid at this size. Paths are nil where the face
        /// has none: small bears drop the stitch, pip and pad.
        func sized(_ path: CGPath?) -> CGPath? {
            var transform = scale
            return path?.copy(using: &transform)
        }
        /// Pins a layer so it turns and scales about this spot on the grid.
        func pin(_ part: CALayer, about point: CGPoint) {
            part.bounds = square
            part.anchorPoint = CGPoint(x: point.x / 24, y: point.y / 24)
            part.position = CGPoint(x: point.x * unit, y: point.y * unit)
        }
        /// A mask that shows only what's outside the head, so outlines don't cross.
        func outsideHead(_ mask: CAShapeLayer, _ head: CGPath) {
            let outside = CGMutablePath()
            outside.addRect(square.insetBy(dx: -side, dy: -side))
            if let sized = sized(head) { outside.addPath(sized) }
            mask.frame = square
            mask.path = outside
            mask.fillRule = .evenOdd
            mask.fillColor = NSColor.black.cgColor
        }

        let small = side < BearGeometry.smallSide
        let face = BearGeometry.waveFace(small: small)
        let eyeBox = face.blinkingEyes?.boundingBox ?? .zero

        pin(arrival, about: BearGeometry.feet)
        pin(figure, about: BearGeometry.feet)
        pin(eyes, about: CGPoint(x: eyeBox.midX, y: eyeBox.midY))
        pin(paw, about: BearGeometry.shoulder)
        armClip.frame = square
        for part in [ears, head, buttonRing, buttonPip, stitch, nose, mouth, arm, pad] { part.frame = square }

        head.path = sized(face.head)
        ears.path = sized(face.ears)
        outsideHead(earMask, face.head)
        outsideHead(armMask, face.head)
        eyes.path = sized(face.blinkingEyes)
        buttonRing.path = sized(face.buttonRing)
        buttonPip.path = sized(face.buttonPip)
        stitch.path = sized(face.stitch)
        nose.path = sized(face.nose)
        mouth.path = sized(face.mouth)
        arm.path = sized(BearGeometry.arm)
        pad.path = sized(BearGeometry.pawPad(small: small))

        for line in [ears, head, arm] { line.lineWidth = BearGeometry.line * unit }
        buttonRing.lineWidth = BearGeometry.Face.buttonWidth * unit
        stitch.lineWidth = BearGeometry.Face.stitchWidth * unit
        mouth.lineWidth = face.mouthWidth * unit
        for line in [stitch, mouth] { line.lineCap = .round }
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
        // The hop, if there's been one: `seconds` counts from the click.
        if let track = arrival.animation(forKey: Key.hop) as? CAKeyframeAnimation,
           let values = track.values as? [NSValue], let times = track.keyTimes?.map(\.doubleValue) {
            let t = min(1, seconds / track.duration)
            let i = times.lastIndex { $0 <= t } ?? 0, j = min(i + 1, values.count - 1)
            let (a, b) = (values[i].caTransform3DValue, values[j].caTransform3DValue)
            let f = min(1, (t - times[i]) / max(0.000_001, times[j] - times[i]))
            let mix = { (x: CGFloat, y: CGFloat) in x + (y - x) * f }
            arrival.setAffineTransform(CGAffineTransform(a: mix(a.m11, b.m11), b: 0, c: 0, d: mix(a.m22, b.m22), tx: 0, ty: mix(a.m42, b.m42)))
        }
        CATransaction.commit()
        layer?.render(in: context)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [paw, figure, eyes, arrival] { part.setAffineTransform(.identity) }
        CATransaction.commit()
    }
    #endif
}
