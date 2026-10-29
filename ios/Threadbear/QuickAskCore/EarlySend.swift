import Foundation

/// Sends the question at a short pause, before it's certain you've finished, so the server is
/// already working while the app waits out the rest of the pause. The answer's held back (not
/// shown or spoken) until the full pause has passed. If you carry on talking, the words change and
/// the early request is dropped, and another goes at the next short pause. If the words at the end
/// are the ones that were sent, the request already running is used, along with whatever it's
/// already received.
///
/// Each request sent, used or not, is one question off the server's allowance (120 an hour).
nonisolated struct EarlySend: Equatable, Sendable {
    /// Long enough that the gaps between words while you're still talking (mostly shorter than
    /// this) don't each send a request, short enough to leave most of the 700 ms default pause for
    /// the server to work in.
    static let pause: TimeInterval = 0.3
    /// The words must also have gone unchanged this long. Only briefly: it's so that words turning
    /// up one at a time while the level's quiet (the recogniser catching up, or a voice too soft for
    /// the level to hear) don't each send a request, which they did in testing, five for one question.
    static let wordsSettle: TimeInterval = 0.2

    /// Whether there's a pause worth sending early on.
    static func isPaused(_ detector: EndOfSpeechDetector, at now: TimeInterval) -> Bool {
        detector.pause(at: now, lasting: pause, wordsStillFor: wordsSettle) != nil
    }

    enum Step: Equatable, Sendable {
        /// The words have changed since the early request went: drop it.
        case cancel
        /// Send this question early.
        case send(String)
    }

    /// The words of the request in flight, if there is one. It stays set if that request fails, so a
    /// failing server (a 429, say) isn't asked again on every check; the full pause asks afresh.
    private(set) var sentWords: [String]?
    /// How many early requests this question has sent, for the log.
    private(set) var sendCount = 0

    /// Called on every check while listening, with the transcript so far and whether there's been
    /// a short pause (`isPaused`).
    mutating func update(transcript: String, paused: Bool) -> [Step] {
        let words = EndOfSpeechDetector.words(in: transcript)
        var steps: [Step] = []
        if let sentWords, sentWords != words {
            steps.append(.cancel)
            self.sentWords = nil
        }
        if sentWords == nil, paused, EndOfSpeechDetector.isMeaningful(transcript) {
            steps.append(.send(transcript.trimmingCharacters(in: .whitespacesAndNewlines)))
            sentWords = words
            sendCount += 1
        }
        return steps
    }

    /// At the end of the full pause (or a tap): whether the request in flight asked this. Only the
    /// words matter, since the recogniser adds the question mark and capitals late.
    func matches(_ transcript: String) -> Bool {
        sentWords != nil && sentWords == EndOfSpeechDetector.words(in: transcript)
    }
}
