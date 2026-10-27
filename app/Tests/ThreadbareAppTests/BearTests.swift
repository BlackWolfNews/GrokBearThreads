import AppKit
import XCTest
@testable import Threadbare

/// The bear is drawn in code: every pose is a template image at any size,
/// with ink in it. Set BEAR_SHEET to a .png path to get a contact sheet of
/// the poses at a few sizes, to look at.
@MainActor
final class BearTests: XCTestCase {
    func testEveryPoseIsATemplateWithInk() {
        for pose in Bear.Pose.allCases {
            for side: CGFloat in [16, 24, 48] {
                let image = Bear.image(pose, side: side)
                XCTAssertTrue(image.isTemplate, "\(pose) \(side)")
                XCTAssertEqual(image.size, NSSize(width: side, height: side))
                XCTAssertGreaterThan(ink(in: image, side: side), 0.03, "\(pose) at \(side) is nearly blank")
                XCTAssertLessThan(ink(in: image, side: side), 0.5, "\(pose) at \(side) is a blob")
            }
            XCTAssertFalse(Bear.description(pose).isEmpty)
        }
        XCTAssertTrue(Bear.image(.sit) === Bear.image(.sit), "cached")
    }

    func testContactSheetWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["BEAR_SHEET"] else { throw XCTSkip("BEAR_SHEET not set") }
        let sizes: [CGFloat] = [14, 18, 26, 48, 96]
        let cell: CGFloat = 110
        let sheet = NSImage(size: NSSize(width: cell * CGFloat(Bear.Pose.allCases.count), height: cell * CGFloat(sizes.count)))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (column, pose) in Bear.Pose.allCases.enumerated() {
            for (row, side) in sizes.enumerated() {
                let image = Bear.image(pose, side: side)
                let tinted = image.copy() as! NSImage
                tinted.isTemplate = false
                let origin = NSPoint(x: cell * CGFloat(column) + (cell - side) / 2, y: cell * CGFloat(row) + (cell - side) / 2)
                tinted.draw(in: NSRect(origin: origin, size: NSSize(width: side, height: side)))
            }
        }
        sheet.unlockFocus()
        let tiff = sheet.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// The share of pixels with any ink, drawn at 2x so thin lines count.
    private func ink(in image: NSImage, side: CGFloat) -> Double {
        let px = Int(side * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let copy = image.copy() as! NSImage
        copy.isTemplate = false
        copy.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for y in 0..<px { for x in 0..<px where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inked += 1 } }
        return Double(inked) / Double(px * px)
    }
}
