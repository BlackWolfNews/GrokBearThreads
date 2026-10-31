import Foundation
import Testing

/// Sending a reply calls Dictation.stop even when the mic was never used, and
/// the audio work in there paused whatever Mike was listening to (31 Oct).
/// The app target can't be imported here, so this reads its source, as
/// MicTapTests does.
struct DictationStopTests {
    @Test func stopLeavesTheAudioAloneUnlessStartTookIt() throws {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: ios.appendingPathComponent("Threadbear/Dictation.swift"), encoding: .utf8)
        let stop = try #require(text.range(of: "func stop()"))
        let body = text[stop.upperBound...]
        let guardLine = try #require(body.range(of: "guard holdsAudio else { return }"))
        for audio in ["engine.", "AVAudioSession."] {
            let first = try #require(body.range(of: audio))
            #expect(guardLine.lowerBound < first.lowerBound, "Dictation.stop touches \(audio) before checking it holds the audio")
        }
    }
}
