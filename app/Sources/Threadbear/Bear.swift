import AppKit

/// The bear: Threadbear's mascot, drawn as line glyphs in code rather than
/// the PNG sprites it started with (docs/threadbear-design/sprites). At
/// sidebar and work-line sizes a painted sprite was a brown smudge; a
/// stroked outline reads at 16 pt and can be drawn at any size. The
/// images are templates, so they take the text colour around them like
/// an SF Symbol. One bear for the app, not one per thread.
enum Bear {
    enum Pose: String, CaseIterable {
        /// Sat, looking at you: the background line while jobs run.
        case sit
        /// A paw up: "Bear with me", the working line.
        case wave
        /// Eyes shut, a couple of Zs: Hibernating.
        case sleep
        /// A smaller bear with big ears: sub-agents out in the background.
        case cub
    }

    /// The working line's bear, in points. A touch bigger than a 16 pt tool
    /// icon so it reads as a character, not a glyph.
    static var workingSide: CGFloat { TypeScale.scaled(26) }

    private static var cache: [String: NSImage] = [:]

    /// The pose as a square template image `side` points across. The
    /// drawing is redone at whatever resolution it's shown at, so the
    /// lines stay crisp on any screen and at any zoom.
    @MainActor
    static func image(_ pose: Pose, side: CGFloat = 24) -> NSImage {
        let key = "\(pose.rawValue)@\(side)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            draw(pose, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(pose)
        cache[key] = image
        return image
    }

    static func description(_ pose: Pose) -> String {
        switch pose {
        case .sit: return "The bear, sat waiting"
        case .wave: return "The bear, waving"
        case .sleep: return "The bear, asleep"
        case .cub: return "A bear cub"
        }
    }

    // MARK: Drawing

    /// Every pose is laid out on a 24 by 24 grid (y down) and scaled to
    /// the rect. Lines are a twelfth of the side or so, round-capped, the
    /// weight of an SF Symbol at the same size.
    static func draw(_ pose: Pose, in rect: NSRect) {
        let scale = min(rect.width, rect.height) / 24
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        NSColor.black.set()
        let lineWidth: CGFloat = 1.6
        switch pose {
        case .wave: drawWave(lineWidth: lineWidth)
        case .sleep: drawSleep(lineWidth: lineWidth)
        case .sit: drawSitting(lineWidth: lineWidth, cub: false)
        case .cub: drawSitting(lineWidth: lineWidth, cub: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A face: round head, two ears peeking out above it, two eyes and a
    /// nose. `eyesShut` draws the eyes as little downward curves.
    private static func drawHead(centre c: NSPoint, radius r: CGFloat, earRadius: CGFloat, lineWidth: CGFloat, eyesShut: Bool = false) {
        // Ears first, clipped to outside the head so the outlines don't
        // cross.
        let head = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: NSRect(x: -10, y: -10, width: 44, height: 44))
        outside.append(head)
        outside.windingRule = .evenOdd
        outside.addClip()
        for sign in [-1.0, 1.0] {
            let ear = NSPoint(x: c.x + sign * r * 0.72, y: c.y - r * 0.72)
            let path = NSBezierPath(ovalIn: NSRect(x: ear.x - earRadius, y: ear.y - earRadius, width: 2 * earRadius, height: 2 * earRadius))
            path.lineWidth = lineWidth
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        head.lineWidth = lineWidth
        head.stroke()
        // Eyes, a little above the middle and apart.
        let eyeY = c.y - r * 0.12
        for sign in [-1.0, 1.0] {
            let x = c.x + sign * r * 0.4
            if eyesShut {
                let shut = NSBezierPath()
                shut.move(to: NSPoint(x: x - r * 0.2, y: eyeY - r * 0.06))
                shut.curve(to: NSPoint(x: x + r * 0.2, y: eyeY - r * 0.06),
                           controlPoint1: NSPoint(x: x - r * 0.1, y: eyeY + r * 0.16),
                           controlPoint2: NSPoint(x: x + r * 0.1, y: eyeY + r * 0.16))
                shut.lineWidth = lineWidth * 0.85
                shut.lineCapStyle = .round
                shut.stroke()
            } else {
                let dot = r * 0.14
                NSBezierPath(ovalIn: NSRect(x: x - dot, y: eyeY - dot, width: 2 * dot, height: 2 * dot)).fill()
            }
        }
        // The nose: a small filled oval, wider than tall, low on the face.
        let noseW = r * 0.34, noseH = r * 0.24
        NSBezierPath(ovalIn: NSRect(x: c.x - noseW / 2, y: c.y + r * 0.3 - noseH / 2, width: noseW, height: noseH)).fill()
    }

    /// `count` little heads side by side, one per login in a pool, as a
    /// template image `height` points tall.
    @MainActor
    static func heads(_ count: Int, height: CGFloat) -> NSImage {
        let key = "heads\(count)@\(height)"
        if let cached = cache[key] { return cached }
        // Each head is 8 by 8 on the grid with a little gap.
        let unit: CGFloat = 8.5
        let width = height * (CGFloat(count) * unit + 0.5) / 9
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            let scale = rect.height / 9
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            NSColor.black.set()
            for i in 0..<count {
                drawHead(centre: NSPoint(x: 4.5 + CGFloat(i) * unit, y: 5.2), radius: 3.2, earRadius: 1.3, lineWidth: 0.9)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// Three stitches across a line: the threadbear bit. `from` to `to`
    /// is the seam; the ticks cross it.
    private static func drawSeam(from a: NSPoint, to b: NSPoint, lineWidth: CGFloat) {
        let seam = NSBezierPath()
        seam.move(to: a)
        seam.line(to: b)
        seam.lineWidth = lineWidth * 0.8
        seam.lineCapStyle = .round
        seam.stroke()
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        // Unit normal to the seam, for the ticks.
        let nx = -dy / length, ny = dx / length
        let tick: CGFloat = 0.9
        for t in [0.25, 0.5, 0.75] {
            let p = NSPoint(x: a.x + dx * t, y: a.y + dy * t)
            let stitch = NSBezierPath()
            stitch.move(to: NSPoint(x: p.x - nx * tick, y: p.y - ny * tick))
            stitch.line(to: NSPoint(x: p.x + nx * tick, y: p.y + ny * tick))
            stitch.lineWidth = lineWidth * 0.7
            stitch.lineCapStyle = .round
            stitch.stroke()
        }
    }

    /// The waving pose's measurements on the grid, shared with
    /// WavingBearView, which draws the same pose in parts it can move.
    enum Wave {
        static let headCentre = NSPoint(x: 10.5, y: 12.5)
        static let headRadius: CGFloat = 7
        static let earRadius: CGFloat = 2.6
        /// Where the arm leaves the head; the paw swings about this.
        static let shoulder = NSPoint(x: 16.4, y: 16.6)
        static let armEnd = NSPoint(x: 20.4, y: 9.4)
        static let armControl1 = NSPoint(x: 19.6, y: 15.6)
        static let armControl2 = NSPoint(x: 21.4, y: 12.4)
        static let paw = NSPoint(x: 20.6, y: 6.6)
        static let pawRadius: CGFloat = 2.4
        static let toeRadius: CGFloat = 0.75
        /// Three toes round the top of the paw.
        static var toes: [NSPoint] {
            [220.0, 270.0, 320.0].map { angle in
                let rad = angle * .pi / 180
                return NSPoint(x: paw.x + cos(rad) * (pawRadius + 1.5), y: paw.y + sin(rad) * (pawRadius + 1.5))
            }
        }
    }

    /// The head to the left, a paw raised at the top right with three
    /// toes, and an arm line between.
    private static func drawWave(lineWidth: CGFloat) {
        drawHead(centre: Wave.headCentre, radius: Wave.headRadius, earRadius: Wave.earRadius, lineWidth: lineWidth)
        // The arm: from the head's lower right up to the paw.
        let arm = NSBezierPath()
        arm.move(to: Wave.shoulder)
        arm.curve(to: Wave.armEnd, controlPoint1: Wave.armControl1, controlPoint2: Wave.armControl2)
        arm.lineWidth = lineWidth
        arm.lineCapStyle = .round
        arm.stroke()
        // The paw: a small circle, three toe arcs on top.
        let paw = Wave.paw, pr = Wave.pawRadius
        let pad = NSBezierPath(ovalIn: NSRect(x: paw.x - pr, y: paw.y - pr, width: 2 * pr, height: 2 * pr))
        pad.lineWidth = lineWidth
        pad.stroke()
        for toe in Wave.toes {
            let dot = Wave.toeRadius
            NSBezierPath(ovalIn: NSRect(x: toe.x - dot, y: toe.y - dot, width: 2 * dot, height: 2 * dot)).fill()
        }
    }

    /// Eyes shut, head tipped a touch, two Zs floating up to the right.
    private static func drawSleep(lineWidth: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let c = NSPoint(x: 10.5, y: 13.5)
        let tilt = NSAffineTransform()
        tilt.translateX(by: c.x, yBy: c.y)
        tilt.rotate(byDegrees: 12)
        tilt.translateX(by: -c.x, yBy: -c.y)
        tilt.concat()
        drawHead(centre: c, radius: 7, earRadius: 2.6, lineWidth: lineWidth, eyesShut: true)
        NSGraphicsContext.restoreGraphicsState()
        drawZ(at: NSPoint(x: 17.2, y: 8.6), size: 2.6, lineWidth: lineWidth * 0.85)
        drawZ(at: NSPoint(x: 20.4, y: 3.6), size: 3.4, lineWidth: lineWidth * 0.85)
    }

    private static func drawZ(at origin: NSPoint, size: CGFloat, lineWidth: CGFloat) {
        let z = NSBezierPath()
        z.move(to: origin)
        z.line(to: NSPoint(x: origin.x + size, y: origin.y))
        z.line(to: NSPoint(x: origin.x, y: origin.y + size))
        z.line(to: NSPoint(x: origin.x + size, y: origin.y + size))
        z.lineWidth = lineWidth
        z.lineCapStyle = .round
        z.lineJoinStyle = .round
        z.stroke()
    }

    /// Head over a round body with a seam down the belly. The cub is
    /// smaller, with ears too big for its head.
    private static func drawSitting(lineWidth: CGFloat, cub: Bool) {
        let r: CGFloat = cub ? 5 : 5.6
        let c = NSPoint(x: 12, y: cub ? 10.2 : 8.6)
        let bodyRect = cub
            ? NSRect(x: 6.4, y: 13.2, width: 11.2, height: 8.6)
            : NSRect(x: 5.2, y: 12.2, width: 13.6, height: 10.6)
        // The body first, clipped to outside the head, as the ears are.
        let head = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: NSRect(x: -10, y: -10, width: 44, height: 44))
        outside.append(head)
        outside.windingRule = .evenOdd
        outside.addClip()
        let body = NSBezierPath(ovalIn: bodyRect)
        body.lineWidth = lineWidth
        body.stroke()
        NSGraphicsContext.restoreGraphicsState()
        drawHead(centre: c, radius: r, earRadius: cub ? 2.6 : 2.1, lineWidth: lineWidth)
        drawSeam(from: NSPoint(x: 12, y: bodyRect.minY + (cub ? 2.4 : 3)), to: NSPoint(x: 12, y: bodyRect.maxY - (cub ? 1.8 : 2.2)), lineWidth: lineWidth)
    }
}
