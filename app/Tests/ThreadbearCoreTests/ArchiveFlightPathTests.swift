import CoreGraphics
import XCTest
@testable import ThreadbearCore

final class ArchiveFlightPathTests: XCTestCase {
    // Window coordinates, y up: the panel's centre on the right, the
    // Archived heading low on the left, as in a short inbox.
    let path = ArchiveFlightPath(start: CGPoint(x: 800, y: 400), end: CGPoint(x: 120, y: 200))

    func testStartsAsThePanelItself() {
        let frame = path.frame(at: 0)
        XCTAssertEqual(frame.position, CGPoint(x: 800, y: 400))
        XCTAssertEqual(frame.scale, 1)
        XCTAssertEqual(frame.tilt, 0, accuracy: 1e-9)
        XCTAssertEqual(frame.opacity, 1)
    }

    func testEndsTinyOnTheHeading() {
        let frame = path.frame(at: 1)
        XCTAssertEqual(frame.position.x, 120, accuracy: 1e-9)
        XCTAssertEqual(frame.position.y, 200, accuracy: 1e-9)
        XCTAssertEqual(frame.scale, ArchiveFlightPath.smallest, accuracy: 1e-9)
        XCTAssertEqual(frame.tilt, 0, accuracy: 1e-9)
        // Still faintly there as it lands, so the bounce follows on from it.
        XCTAssertEqual(frame.opacity, 0.2, accuracy: 1e-9)
    }

    /// It swings: early on it's moved further down than across, and it's
    /// below the straight line between the two.
    func testFallsBeforeItSwingsAcross() {
        let early = path.frame(at: 0.25).position
        XCTAssertGreaterThan(400 - early.y, 800 - early.x)
        let middle = path.frame(at: 0.5).position
        let straightY = 400 + (middle.x - 800) / (120 - 800) * (200 - 400)
        XCTAssertLessThan(middle.y, straightY)
    }

    func testShrinksAndTipsOnTheWay() {
        let frames = stride(from: 0.0, through: 1.0, by: 0.1).map { path.frame(at: $0) }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(b.scale, a.scale)
        }
        XCTAssertGreaterThan(path.frame(at: 0.5).tilt, 0)
        XCTAssertEqual(path.frame(at: 0.5).opacity, 1)
    }

    /// With the heading out of sight it falls off the bottom of the list,
    /// gone by the end.
    func testOffTheListFadesAllTheWay() {
        let off = ArchiveFlightPath(start: path.start, end: path.end, onHeading: false)
        XCTAssertEqual(off.frame(at: 1).opacity, 0, accuracy: 1e-9)
        XCTAssertLessThan(off.frame(at: 0.8).opacity, path.frame(at: 0.8).opacity)
    }

    func testProgressEasesInAndOut() {
        XCTAssertEqual(ArchiveFlightPath.progress(atTime: 0), 0)
        XCTAssertEqual(ArchiveFlightPath.progress(atTime: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ArchiveFlightPath.progress(atTime: 1), 1)
        XCTAssertEqual(ArchiveFlightPath.progress(atTime: 2), 1)
        XCTAssertLessThan(ArchiveFlightPath.progress(atTime: 0.1), 0.1)
        XCTAssertGreaterThan(ArchiveFlightPath.progress(atTime: 0.9), 0.9)
    }
}
