import Foundation
import Testing

/// Opening the app must leave other apps' audio alone. Preparing the audio engine
/// and rendering a word of speech at launch went with a playing podcast stopping
/// on open (1 Nov), so both wait until someone asks. This reads the app's sources,
/// as MicTapTests does, since the sound only stops on a real phone.
struct QuietLaunchTests {
    private func body(of signature: String, in file: String) throws -> String {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: ios.appendingPathComponent(file), encoding: .utf8)
        let start = try #require(text.range(of: signature), "\(signature) not found in \(file)")
        let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    @Test func launchPreparationLeavesAudioAlone() throws {
        let prepare = try body(of: "private func prepare()", in: "Threadbear/QuickAsk/QuickAskModel.swift")
        for call in ["prewarm(", "startEarly(", "warmUpVoice(", ".start("] {
            #expect(!prepare.contains(call), "prepare() runs on every launch, so it can't call \(call)")
        }
    }

    @Test func pickingTheVoiceDoesNotRenderSpeech() throws {
        let select = try body(of: "func selectVoiceInBackground", in: "Threadbear/QuickAsk/Speaker.swift")
        #expect(!select.contains("warmUp"))
    }
}
