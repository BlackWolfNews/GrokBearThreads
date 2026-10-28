import AppKit
import ThreadbearCore

/// The model picker's honey pots: one per model, fuller for a bigger
/// model (Mike picked these over bears of different sizes, 28 Oct; the
/// mockups are in docs/model-icons-design). Line glyphs drawn in code and
/// used as templates, like Bear, so they take the text colour around them.
enum HoneyPot {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ honey: ModelPicker.Honey, side: CGFloat) -> NSImage {
        let key = "\(honey)@\(side)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            draw(honey, in: rect)
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// On a 24 by 24 grid (y down), scaled to the rect: a lid, a rim and a
    /// rounded pot, with the honey a fainter fill clipped to the pot.
    private static func draw(_ honey: ModelPicker.Honey, in rect: NSRect) {
        let scale = min(rect.width, rect.height) / 24
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        let lineWidth: CGFloat = 1.7

        let pot = NSBezierPath()
        pot.move(to: NSPoint(x: 6, y: 7.5))
        pot.line(to: NSPoint(x: 18, y: 7.5))
        pot.curve(to: NSPoint(x: 17, y: 20.5), controlPoint1: NSPoint(x: 19.5, y: 10.5), controlPoint2: NSPoint(x: 19.5, y: 17.5))
        pot.line(to: NSPoint(x: 7, y: 20.5))
        pot.curve(to: NSPoint(x: 6, y: 7.5), controlPoint1: NSPoint(x: 4.5, y: 17.5), controlPoint2: NSPoint(x: 4.5, y: 10.5))
        pot.close()

        let level: CGFloat
        switch honey {
        case .little: level = 0.25
        case .half: level = 0.55
        case .full, .special: level = 0.9
        }
        let top = 20.5 - 13 * level
        NSGraphicsContext.saveGraphicsState()
        pot.addClip()
        NSColor.black.withAlphaComponent(0.6).set()
        NSRect(x: 3, y: top, width: 18, height: 21 - top).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.set()
        pot.lineWidth = lineWidth
        pot.lineJoinStyle = .round
        pot.stroke()
        let rim = NSBezierPath()
        rim.move(to: NSPoint(x: 5, y: 7.5))
        rim.line(to: NSPoint(x: 19, y: 7.5))
        rim.lineWidth = lineWidth
        rim.lineCapStyle = .round
        rim.stroke()
        let lid = NSBezierPath(roundedRect: NSRect(x: 7, y: 4, width: 10, height: 3.5), xRadius: 0.8, yRadius: 0.8)
        lid.lineWidth = lineWidth
        lid.stroke()

        if honey == .special {
            // A five-point star on the pot, solid.
            let star = NSBezierPath()
            let centre = NSPoint(x: 12, y: 14.2)
            for i in 0..<10 {
                let r: CGFloat = i % 2 == 0 ? 3.2 : 1.35
                let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let p = NSPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
                i == 0 ? star.move(to: p) : star.line(to: p)
            }
            star.close()
            star.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
