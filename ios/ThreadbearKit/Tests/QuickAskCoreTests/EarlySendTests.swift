import Testing
@testable import QuickAskCore

struct EarlySendTests {
    @Test func sendsOnceAtAShortPause() {
        var early = EarlySend()
        #expect(early.update(transcript: "What did I", paused: false) == [])
        #expect(early.update(transcript: "What did I do yesterday", paused: true) == [.send("What did I do yesterday")])
        // Still paused, same words: nothing more goes
        #expect(early.update(transcript: "What did I do yesterday", paused: true) == [])
        #expect(early.sendCount == 1)
        #expect(early.matches("What did I do yesterday"))
    }

    @Test func carryingOnCancelsThenSendsAgainAtTheNextPause() {
        var early = EarlySend()
        _ = early.update(transcript: "What did I", paused: true)
        #expect(early.update(transcript: "What did I decide", paused: false) == [.cancel])
        #expect(!early.matches("What did I decide"))
        #expect(early.update(transcript: "What did I decide about the muse", paused: false) == [])
        #expect(early.update(transcript: "What did I decide about the muse", paused: true) == [.send("What did I decide about the muse")])
        #expect(early.sendCount == 2)
        #expect(early.matches("What did I decide about the muse"))
    }

    @Test func cancelsAndSendsAgainInOneGoIfItsStillAPause() {
        var early = EarlySend()
        _ = early.update(transcript: "Where does T3 code", paused: true)
        #expect(early.update(transcript: "Where does T3 code live", paused: true) == [.cancel, .send("Where does T3 code live")])
    }

    @Test func punctuationAndCapitalsKeepTheRequest() {
        var early = EarlySend()
        _ = early.update(transcript: "where is paris", paused: true)
        #expect(early.update(transcript: "Where is Paris?", paused: true) == [])
        #expect(early.matches("Where is Paris?"))
        #expect(early.sendCount == 1)
    }

    @Test func nothingWorthSendingIsntSent() {
        var early = EarlySend()
        #expect(early.update(transcript: "Um", paused: true) == [])
        #expect(early.update(transcript: "", paused: true) == [])
        #expect(!early.matches(""))
        #expect(early.sendCount == 0)
    }

    @Test func nothingSentMatchesNothing() {
        let early = EarlySend()
        #expect(!early.matches("What did I do yesterday"))
    }

    /// The detector and EarlySend together, as AskModel drives them: a buffer every 20 ms, a check
    /// after each. Mike pauses mid-question, carries on, then stops.
    @Test func midQuestionPauseThenTheRealEnd() throws {
        var detector = EndOfSpeechDetector()
        var early = EarlySend()
        var steps: [(time: Double, step: EarlySend.Step)] = []
        var endedAt: Double?
        var decidedAt: Double?
        // Talking from 0.4 to 1.4 s, then from 1.9 to 2.5 s. The last word turns up 400 ms after
        // the voice stopped, as the recogniser catches up.
        let words: [(Double, String)] = [
            (0.7, "So what"), (1.0, "So what about"), (1.3, "So what about the"),
            (2.3, "So what about the muse"), (2.9, "So what about the muse video"),
        ]
        var next = 0
        var t = 0.0
        while t < 4, decidedAt == nil {
            let talking = (t >= 0.4 && t < 1.4) || (t >= 1.9 && t < 2.5)
            detector.audioLevel(talking ? -25 : -62, at: t)
            while next < words.count, words[next].0 <= t {
                detector.transcriptChanged(words[next].1, at: t)
                next += 1
            }
            if let end = detector.endOfSpeech(at: t) {
                endedAt = end
                decidedAt = t
                break
            }
            for step in early.update(transcript: detector.transcript, paused: EarlySend.isPaused(detector, at: t)) {
                steps.append((t, step))
            }
            t += 0.02
        }

        // Nothing goes at the mid-question pause, since "So what about the" stops mid-sentence. Sent
        // at the next pause, then again when the late last word came in
        #expect(steps.map(\.step) == [.send("So what about the muse"), .cancel, .send("So what about the muse video")])
        try #require(steps.count == 3)
        #expect(abs(steps[0].time - 2.78) < 0.03)              // 300 ms after the voice stopped at 2.48
        #expect(abs(steps[1].time - 2.9) < 0.03)               // "video", already 420 ms into the pause
        #expect(abs(steps[2].time - 3.1) < 0.03)               // once it's been there 200 ms
        // The full pause is timed from the voice, and waits for the late word to settle (350 ms);
        // its words match, so the request sent at 3.1 is the one used
        #expect(endedAt != nil && abs(endedAt! - 2.48) < 0.03)
        #expect(decidedAt != nil && abs(decidedAt! - 3.26) < 0.03)
        #expect(early.matches(detector.transcript))
        #expect(early.sendCount == 2)
    }
}
