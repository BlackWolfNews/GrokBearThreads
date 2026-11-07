import AppKit
import XCTest
@testable import Threadbear

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

    /// The working line's moving bear is the still pose cut into layers, so
    /// at rest the two have to look the same, or the bear jumps between the
    /// working line and everywhere else.
    func testTheMovingBearAtRestMatchesTheStillPose() {
        let side: CGFloat = 96
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.tint = .black
        let moving = inkMap(side: Int(side)) { view.renderStill(in: $0) }
        let still = inkMap(side: Int(side)) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: 1, y: -1)
            Bear.draw(.wave, in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
        }
        let inked = still.filter { $0 }.count
        XCTAssertGreaterThan(inked, 500, "the pose should have ink in it")
        let different = zip(moving, still).filter { $0 != $1 }.count
        XCTAssertLessThan(Double(different) / Double(inked), 0.03, "\(different) of \(inked) pixels differ")
    }

    /// The Mac and the iPhone share no package, so the drawing is the same
    /// file in both. Change one, copy it to the other.
    func testBothAppsDrawTheSameBear() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mac = try String(contentsOf: repo.appendingPathComponent("app/Sources/Threadbear/BearGeometry.swift"), encoding: .utf8)
        let phone = try String(contentsOf: repo.appendingPathComponent("ios/Threadbear/BearGeometry.swift"), encoding: .utf8)
        XCTAssertEqual(mac, phone, "copy app/Sources/Threadbear/BearGeometry.swift over ios/Threadbear/BearGeometry.swift")
    }

    /// Tiny specks go when the bear's small, and a cub has both its eyes.
    func testSmallBearsDropTheirSpecksAndCubsHaveNoButton() {
        let big = BearGeometry.waveFace(small: false), small = BearGeometry.waveFace(small: true)
        XCTAssertNotNil(big.stitch)
        XCTAssertNotNil(big.buttonPip)
        XCTAssertNil(small.stitch)
        XCTAssertNil(small.buttonPip)
        XCTAssertNotNil(small.buttonRing, "the button itself stays, it's the bear's whole character")
        XCTAssertNil(BearGeometry.pawPad(small: true))
        let cub = BearGeometry.Face(centre: .zero, scale: 0.6, eyes: .plain)
        XCTAssertNil(cub.buttonRing)
    }

    func testItMovesUntilStoppedAndStaysStillUnderReduceMotion() {
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        view.start(fresh: false, reduceMotion: true)
        XCTAssertFalse(view.isAnimating)
        view.start(fresh: true, reduceMotion: false)
        XCTAssertTrue(view.isAnimating)
        view.stop()
        XCTAssertFalse(view.isAnimating)
    }

    /// The wave has to begin and end at rest, or it jumps as it repeats,
    /// and it has to fit its loop with most of the time spent still.
    func testTheWaveIsABurstThatStartsAndEndsAtRest() {
        let keys = WavingBearView.Timing.paw
        XCTAssertEqual(keys.first?.degrees, 0)
        XCTAssertEqual(keys.last?.degrees, 0)
        XCTAssertEqual(keys.last?.at, WavingBearView.Timing.wave)
        XCTAssertEqual(keys.map(\.at), keys.map(\.at).sorted())
        let lastMove = keys.dropLast().last!.at
        XCTAssertLessThan(lastMove / WavingBearView.Timing.wave, 0.5, "the bear should rest more than it waves")
    }

    /// Rest the pointer on the bear and it waves back at once, but only every
    /// few seconds however much the pointer wiggles, and only while it's a
    /// working bear: a finished line's stays still.
    func testItWavesBackAtThePointerNowAndThen() {
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        XCTAssertFalse(view.waveBack(at: 1000), "not started, so nothing's there to wave")
        view.start(fresh: false, reduceMotion: false)
        XCTAssertTrue(view.waveBack(at: 1000))
        XCTAssertFalse(view.waveBack(at: 1000 + WavingBearView.Timing.waveBackGap - 0.1))
        XCTAssertTrue(view.waveBack(at: 1000 + WavingBearView.Timing.waveBackGap))
        view.stop()
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(view.waveBack(at: 2000), "a finished line")
        XCTAssertFalse(view.hop(at: 2000), "a finished line")
        XCTAssertFalse(view.isAnimating, "and the pointer doesn't start it up again")
    }

    func testAPointerOverItReallyWaves() throws {
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first)
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.inVisibleRect), "it has to follow the bear's own size, which is set after it's made")
        XCTAssertTrue(area.owner === view)
    }

    func testTheHopStartsAndEndsOnTheGroundAndIsNotInterrupted() {
        let keys = WavingBearView.Timing.hopKeys
        XCTAssertEqual(keys.first?.up, 0)
        XCTAssertEqual(keys.first?.y, 1)
        XCTAssertEqual(keys.last?.up, 0)
        XCTAssertEqual(keys.last?.y, 1)
        XCTAssertEqual(keys.last?.at, 1)
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        view.start(fresh: false, reduceMotion: false)
        XCTAssertTrue(view.hop(at: 1000))
        XCTAssertFalse(view.hop(at: 1000 + WavingBearView.Timing.hop / 2), "already in the air")
        XCTAssertTrue(view.hop(at: 1000 + WavingBearView.Timing.hop + 0.01))
    }

    /// Under Reduce Motion the bear doesn't move, but it still sees you.
    func testReduceMotionGetsABlinkAndNoMovement() {
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        view.start(fresh: false, reduceMotion: true)
        XCTAssertTrue(view.waveBack(at: 1000))
        XCTAssertTrue(view.hop(at: 1000))
        XCTAssertFalse(view.isAnimating)
    }

    /// Set BEAR_FRAMES to a folder to get the moving bear as numbered PNGs,
    /// to look at or turn into a GIF. Drawn 8pt in from each edge, so a paw
    /// swinging past the frame shows.
    func testFramesWhenAsked() throws {
        guard let folder = ProcessInfo.processInfo.environment["BEAR_FRAMES"] else { throw XCTSkip("BEAR_FRAMES not set") }
        // BEAR_FRAMES_HOP: the hop on a click instead, from the click on.
        let hopping = ProcessInfo.processInfo.environment["BEAR_FRAMES_HOP"] != nil
        let side = 192, pad = hopping ? 96 : 32, canvas = side + 2 * pad
        let view = WavingBearView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.tint = .black
        view.start(fresh: false, reduceMotion: false)
        if hopping { view.hop() }
        for frame in 0..<(hopping ? 15 : 8 * 30) {
            let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            context.translateBy(x: CGFloat(pad), y: CGFloat(pad))
            view.renderFrame(at: Double(frame) / 30, in: context)
            let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "f%04d.png", frame)))
        }
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

    /// Which pixels have ink when `draw` paints a square of `side` pixels.
    private func inkMap(side: Int, draw: (CGContext) -> Void) -> [Bool] {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return (0..<side * side).map { pixels[$0 * 4 + 3] > 127 }
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
