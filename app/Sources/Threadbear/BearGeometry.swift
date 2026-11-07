import CoreGraphics

/// The line bear as paths on a 24 by 24 grid (y down): the one drawing behind
/// every pose, on the Mac and the iPhone. It was redrawn on 7 Nov 2026 to look
/// like the Dock icon, as the old one read more like a koala: a wide head with
/// small ears set wide, a nose and smile, a stitch, and one button eye, picked
/// from sketches in ~/dev/me/misc/threadbear-juice-mockups/bear-lab.
///
/// This file is identical in app/Sources/Threadbear and ios/Threadbear, as
/// the two apps share no package. BearTests fails if they differ.
enum BearGeometry {
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

    /// The main line's weight on the grid, about an SF Symbol's at this size.
    static let line: CGFloat = 1.6

    /// Below this many points the stitch, the button's pip and the paw's pad
    /// are just specks, so they go, the way SF Symbols thin out when small.
    static let smallSide: CGFloat = 20

    /// One thing to draw: stroked at `width`, or filled when that's nil,
    /// showing only outside `outside` when it's set, so outlines never cross.
    struct Ink {
        var path: CGPath
        var width: CGFloat?
        var outside: CGPath? = nil
    }

    enum Eyes { case button, plain, shut }

    /// A head, centred at `centre` and `scale` times the full-size one. Its
    /// parts move about the grid with it, but the line weights stay the same.
    struct Face {
        var centre: CGPoint
        var scale: CGFloat
        var eyes: Eyes = .button
        var bigEars = false
        var stitched = true
        var small = false

        /// A point on the full-size head (centre 12, 13.2), placed on this one.
        private func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + (x - 12) * scale, y: centre.y + (y - 13.2) * scale)
        }
        /// Eyes shrink less than the head does, or they vanish on the sat bear.
        private var eyeScale: CGFloat { max(scale, 0.8) }

        var head: CGPath { ellipse(centre, 8.8 * scale, 8 * scale) }

        var ears: CGPath {
            let r = 3 * scale * (bigEars ? 1.28 : 1)
            let path = CGMutablePath()
            path.addPath(ellipse(at(5.3, 6.1), r, r))
            path.addPath(ellipse(at(18.7, 6.1), r, r))
            return path
        }

        /// The eye that blinks: the left one, or both on a cub. Nil when shut.
        var blinkingEyes: CGPath? {
            let r = 1.15 * eyeScale
            switch eyes {
            case .shut: return nil
            case .button: return ellipse(at(8, 11.6), r, r)
            case .plain:
                let path = CGMutablePath()
                path.addPath(ellipse(at(8, 11.6), r, r))
                path.addPath(ellipse(at(16, 11.6), r, r))
                return path
            }
        }

        /// The button sewn on in place of an eye. It's a button, so it doesn't blink.
        var buttonRing: CGPath? {
            eyes == .button ? ellipse(at(15.8, 11.4), 2.15 * scale, 2.15 * scale) : nil
        }
        var buttonPip: CGPath? {
            eyes == .button && !small ? ellipse(at(15.8, 11.4), 0.55 * eyeScale, 0.55 * eyeScale) : nil
        }
        static let buttonWidth = line * 0.72

        var shutEyes: CGPath? {
            guard eyes == .shut else { return nil }
            let path = CGMutablePath()
            for x: CGFloat in [8, 16] {
                let mid = at(x, 11.2), w = 1.6 * scale
                path.move(to: CGPoint(x: mid.x - w, y: mid.y))
                path.addQuadCurve(to: CGPoint(x: mid.x + w, y: mid.y), control: CGPoint(x: mid.x, y: mid.y + 1.4 * scale))
            }
            return path
        }
        static let shutWidth = line * 0.85

        /// The forehead stitch, over the good eye like a brow: a line and two ticks.
        var stitch: CGPath? {
            guard stitched, !small else { return nil }
            let path = CGMutablePath()
            for (from, to) in [(at(7.6, 8.4), at(11, 7.2)), (at(8.6, 7.1), at(9.1, 8.6)), (at(10, 6.6), at(10.4, 8.1))] {
                path.move(to: from)
                path.addLine(to: to)
            }
            return path
        }
        static let stitchWidth = line * 0.5

        var nose: CGPath { ellipse(at(12, 15.6), 1.9 * scale, 1.35 * scale) }

        var mouth: CGPath {
            let path = CGMutablePath()
            path.move(to: at(9.8, 18))
            path.addQuadCurve(to: at(14.2, 18), control: at(12, 19.7))
            return path
        }
        /// Thinner on a smaller head, where it would otherwise touch the nose.
        var mouthWidth: CGFloat { line * (scale < 0.75 ? 0.62 : 0.72) }

        /// All of the face but the eye that blinks, which moves on its own.
        var stillInks: [Ink] {
            var all = [Ink(path: ears, width: line, outside: head), Ink(path: head, width: line)]
            if let buttonRing { all.append(Ink(path: buttonRing, width: Self.buttonWidth)) }
            if let buttonPip { all.append(Ink(path: buttonPip, width: nil)) }
            if let shutEyes { all.append(Ink(path: shutEyes, width: Self.shutWidth)) }
            if let stitch { all.append(Ink(path: stitch, width: Self.stitchWidth)) }
            all.append(Ink(path: nose, width: nil))
            all.append(Ink(path: mouth, width: mouthWidth))
            return all
        }

        var inks: [Ink] {
            stillInks + (blinkingEyes.map { [Ink(path: $0, width: nil)] } ?? [])
        }
    }

    // MARK: Waving

    /// The waving pose, in the parts the moving bears move.
    static func waveFace(small: Bool) -> Face { Face(centre: CGPoint(x: 9, y: 12.76), scale: 0.8, small: small) }
    /// Where the arm leaves the head; the paw swings about this.
    static let shoulder = CGPoint(x: 14.5, y: 16)
    /// The spot on the grid the bear rocks and breathes about.
    static let feet = CGPoint(x: 9, y: 19.2)

    /// A stubby capsule coming out from behind the head, drawn only outside
    /// it so it hugs the head. A stick and a ring read as a lollipop, an arm
    /// joined at both ends as a teacup handle, and a paw on its own as a blob.
    static var arm: CGPath {
        let tip = CGPoint(x: 21, y: 9.8), w: CGFloat = 2.2
        let dx = tip.x - shoulder.x, dy = tip.y - shoulder.y
        let length = (dx * dx + dy * dy).squareRoot()
        var place = CGAffineTransform(translationX: shoulder.x, y: shoulder.y).rotated(by: atan2(dy, dx))
        return CGPath(roundedRect: CGRect(x: -w, y: -w, width: length + 2 * w, height: 2 * w), cornerWidth: w, cornerHeight: w, transform: &place)
    }
    /// The pad on the paw. Nil when small.
    static func pawPad(small: Bool) -> CGPath? { small ? nil : ellipse(CGPoint(x: 21.05, y: 9.9), 0.95, 0.85) }

    // MARK: Poses

    /// Everything in a pose, in drawing order. `side` is the size it's shown at.
    static func inks(_ pose: Pose, side: CGFloat) -> [Ink] {
        let small = side < smallSide
        switch pose {
        case .wave:
            let face = waveFace(small: small)
            var all = [Ink(path: arm, width: line, outside: face.head)]
            if let pad = pawPad(small: small) { all.append(Ink(path: pad, width: nil)) }
            return all + face.inks
        case .sleep:
            let centre = CGPoint(x: 8.5, y: 15.4)
            let face = Face(centre: centre, scale: 0.8, eyes: .shut, small: small)
            // The head tips over, as it drops off.
            var tip = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: 8 * .pi / 180).translatedBy(x: -centre.x, y: -centre.y)
            let tipped = face.inks.map { ink in
                Ink(path: ink.path.copy(using: &tip) ?? ink.path, width: ink.width, outside: ink.outside?.copy(using: &tip))
            }
            return tipped + [Ink(path: z(CGPoint(x: 18.4, y: 6.4), 2.2), width: Face.shutWidth), Ink(path: z(CGPoint(x: 21, y: 1), 2.9), width: Face.shutWidth)]
        case .sit:
            let face = Face(centre: CGPoint(x: 12, y: 8.9), scale: 0.72, small: small)
            return body(centre: CGPoint(x: 12, y: 17.8), rx: 6, ry: 5, feetApart: 5.5, feetY: 21.7, footRx: 2.5, footRy: 1.8, face: face) + face.inks
        case .cub:
            // Small and new: big ears, both its eyes, nothing stitched yet.
            let face = Face(centre: CGPoint(x: 12, y: 11.2), scale: 0.62, eyes: .plain, bigEars: true, stitched: false, small: small)
            return body(centre: CGPoint(x: 12, y: 19.4), rx: 4.3, ry: 3.4, feetApart: 3.9, feetY: 22.2, footRx: 1.8, footRy: 1.3, face: face) + face.inks
        }
    }

    /// A plump body behind the head with two feet stuck out, which stop it
    /// looking like a snowman.
    private static func body(centre: CGPoint, rx: CGFloat, ry: CGFloat, feetApart: CGFloat, feetY: CGFloat, footRx: CGFloat, footRy: CGFloat, face: Face) -> [Ink] {
        let feet = CGMutablePath()
        feet.addPath(ellipse(CGPoint(x: centre.x - feetApart, y: feetY), footRx, footRy))
        feet.addPath(ellipse(CGPoint(x: centre.x + feetApart, y: feetY), footRx, footRy))
        let inFront = CGMutablePath()
        inFront.addPath(face.head)
        inFront.addPath(feet)
        return [Ink(path: ellipse(centre, rx, ry), width: line, outside: inFront), Ink(path: feet, width: line)]
    }

    private static func z(_ origin: CGPoint, _ size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
        path.addLine(to: CGPoint(x: origin.x + size, y: origin.y + size))
        return path
    }

    fileprivate static func ellipse(_ centre: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }
}
