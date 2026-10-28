import AppKit
import XCTest
@testable import Threadbear

/// The swipe's whoosh is made in code. Set WHOOSH_WAV to a .wav path to
/// get it as a file, to listen to.
@MainActor
final class WhooshTests: XCTestCase {
    func testItsAShortSoundThatPlays() throws {
        let samples = Whoosh.render()
        XCTAssertEqual(Double(samples.count) / Whoosh.rate, 0.26, accuracy: 0.01)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.8, accuracy: 0.001)
        // Starts and ends silent, so it never clicks.
        XCTAssertLessThan(abs(samples.first ?? 1), 0.01)
        XCTAssertLessThan(samples.suffix(50).map(abs).max() ?? 1, 0.01)
        let data = Whoosh.wav(samples: samples)
        let sound = try XCTUnwrap(NSSound(data: data))
        XCTAssertEqual(sound.duration, 0.26, accuracy: 0.01)
        if let path = ProcessInfo.processInfo.environment["WHOOSH_WAV"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
