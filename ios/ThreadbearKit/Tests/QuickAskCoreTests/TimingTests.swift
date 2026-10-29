import Foundation
import Testing
@testable import QuickAskCore

struct TimingTests {
    private func sample(spoke: Bool = true) -> QuestionTiming {
        var timing = QuestionTiming(trigger: .launch, pressAt: 100.000)
        timing.spoke = spoke
        timing.micLiveAt = 100.180
        timing.endOfSpeechAt = 103.000
        timing.sendDecidedAt = 103.700
        timing.requestSentAt = 103.705
        timing.responseAt = 104.100
        timing.firstByteAt = 104.150
        timing.firstSpokenAt = 104.400
        timing.completeAt = 105.000
        timing.serverTiming = [ServerTimingEntry(name: "auth", durationMs: 12), ServerTimingEntry(name: "retrieve", durationMs: 340)]
        return timing
    }

    private func close(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.5
    }

    @Test func durations() {
        let timing = sample()
        #expect(close(timing.pressToMic, 180))
        #expect(close(timing.endToRequest, 705))
        #expect(close(timing.silenceWait, 700))
        #expect(close(timing.requestToFirstByte, 445))
        #expect(close(timing.firstByteToFirstWord, 250))
        #expect(close(timing.endToFirstWord, 1400))
        #expect(close(timing.streamDuration, 850))
        #expect(timing.headline == "1.40 s to first word")
    }

    @Test func withSpeakingOffTheHeadlineIsFirstText() {
        let timing = sample(spoke: false)
        #expect(close(timing.endToFirstWord, 1150))
        #expect(close(timing.firstByteToFirstWord, 0))
        #expect(timing.headline == "1.15 s to first text")
    }

    @Test func missingMomentsLeaveDurationsOut() {
        var timing = QuestionTiming(trigger: .debug)
        timing.requestSentAt = 10
        #expect(timing.pressToMic == nil)
        #expect(timing.endToFirstWord == nil)
        #expect(timing.headline == nil)
        #expect(timing.breakdown.isEmpty)
    }

    @Test func negativeGapsClampToZero() {
        // The intent can be delivered after the mic is already live on a cold launch
        var timing = QuestionTiming(trigger: .intent, pressAt: 5.2)
        timing.micLiveAt = 5.0
        #expect(timing.pressToMic == 0)
    }

    @Test func breakdownIncludesServerTiming() {
        let rows = sample().breakdown
        #expect(rows.first?.label == "Press to mic live")
        #expect(rows.contains { $0.label == "  server" && $0.value == "auth 12 ms, retrieve 340 ms" })
        #expect(rows.contains { $0.label == "End of speech to first spoken word" && $0.value == "1.40 s" })
        // Not sent early: no early rows
        #expect(!rows.contains { $0.label.contains("hidden") || $0.label.contains("end of pause") })
    }

    @Test func breakdownLeavesOutCloudflaresServerTiming() {
        // Saved before Cloudflare's entries were dropped on arrival
        var timing = sample()
        timing.serverTiming.append(ServerTimingEntry(name: "cfExtPri", durationMs: nil))
        #expect(timing.breakdown.contains { $0.label == "  server" && $0.value == "auth 12 ms, retrieve 340 ms" })
        timing.serverTiming = [ServerTimingEntry(name: "cfExtPri", durationMs: nil)]
        #expect(!timing.breakdown.contains { $0.label == "  server" })
    }

    /// Stopped talking at 103.0, sent early at a 300 ms pause, the full pause ran out at 103.7.
    private func sentEarly(firstByteAt: Double) -> QuestionTiming {
        var timing = QuestionTiming(trigger: .resume, pressAt: 100)
        timing.micLiveAt = 100.9
        timing.endOfSpeechAt = 103.000
        timing.sendDecidedAt = 103.300
        timing.requestSentAt = 103.302
        timing.pauseEndedAt = 103.700
        timing.firstByteAt = firstByteAt
        timing.firstSpokenAt = max(firstByteAt, 103.700) + 0.15
        timing.completeAt = firstByteAt + 1
        return timing
    }

    @Test func sentEarlyWithASlowServer() {
        let timing = sentEarly(firstByteAt: 105.302)                  // 2 s of server
        #expect(timing.sentEarly)
        #expect(close(timing.endToRequest, 302))
        #expect(close(timing.silenceWait, 300))
        #expect(close(timing.fullPause, 700))
        #expect(close(timing.requestToFirstByte, 2000))
        #expect(close(timing.hiddenByEarlySend, 398))                 // the rest of the pause
        #expect(close(timing.firstByteToFirstWord, 150))
        #expect(close(timing.endToFirstWord, 2452))                   // 398 ms sooner than sending at 103.7
        let rows = timing.breakdown
        #expect(rows.contains { $0.label == "End of speech to end of pause" && $0.value == "700 ms" })
        #expect(rows.contains { $0.label == "  of which hidden behind the pause" && $0.value == "398 ms" })
    }

    @Test func sentEarlyWithTheAnswerInBeforeThePauseEnded() {
        let timing = sentEarly(firstByteAt: 103.500)                  // a quick answer, held back
        #expect(close(timing.hiddenByEarlySend, 198))                 // all of the request's wait
        #expect(close(timing.firstByteToFirstWord, 150))              // from the end of the pause, not the byte
        #expect(close(timing.endToFirstWord, 850))
        var shown = timing
        shown.spoke = false
        #expect(close(shown.endToFirstWord, 700))                     // shown when the pause ran out
    }

    @Test func notSentEarlyHasNoHiddenTime() {
        var timing = sample()
        timing.pauseEndedAt = 103.700                                 // the same moment it was decided
        #expect(!timing.sentEarly)
        #expect(timing.hiddenByEarlySend == nil)
        #expect(close(timing.fullPause, 700))
        #expect(close(timing.firstByteToFirstWord, 250))
    }

    @Test func formatting() {
        #expect(TimingFormat.duration(84.4) == "84 ms")
        #expect(TimingFormat.duration(999.4) == "999 ms")
        #expect(TimingFormat.duration(1236) == "1.24 s")
        #expect(TimingFormat.server([ServerTimingEntry(name: "auth", durationMs: nil)]) == "auth")
    }

    @Test func logKeepsTheLatestTwentyAndUpdatesInPlace() {
        var log = TimingLog()
        var first = sample()
        log.record(first)
        first.completeAt = 106
        log.record(first)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].completeAt == 106)
        for _ in 0..<25 { log.record(sample()) }
        #expect(log.entries.count == 20)
        #expect(log.entries.last?.id != first.id)
    }

    @Test func medianHeadline() {
        var log = TimingLog()
        for ms in [900.0, 1500, 1100] {
            var timing = QuestionTiming(trigger: .followUp)
            timing.endOfSpeechAt = 0
            timing.firstSpokenAt = ms / 1000
            log.record(timing)
        }
        #expect(close(log.medianEndToFirstWord, 1100))
    }

    @Test func roundTripsThroughJSON() throws {
        let timing = sample()
        let decoded = try JSONDecoder().decode(QuestionTiming.self, from: JSONEncoder().encode(timing))
        #expect(decoded == timing)
    }
}

struct ConversationTests {
    @Test func keepsTheLastThree() {
        var conversation = Conversation()
        for i in 1...5 { conversation.add(question: "Q\(i)", answer: "A\(i)") }
        conversation.add(question: "Q6", answer: "  ")
        #expect(conversation.exchanges.map(\.question) == ["Q3", "Q4", "Q5"])
    }

    @Test func forgetsAfterTenMinutesInTheBackground() {
        var conversation = Conversation()
        conversation.add(question: "Q", answer: "A")
        let start = Date()
        conversation.didEnterBackground(at: start)
        let clearedEarly = conversation.didBecomeActive(at: start.addingTimeInterval(9 * 60))
        #expect(!clearedEarly)
        #expect(!conversation.isEmpty)
        conversation.didEnterBackground(at: start)
        let cleared = conversation.didBecomeActive(at: start.addingTimeInterval(10 * 60 + 1))
        #expect(cleared)
        #expect(conversation.isEmpty)
    }
}

struct VoiceRankingTests {
    @Test func qualityFirstThenAustralianOrBritish() {
        let voices = [
            VoiceInfo(id: "us-def", name: "Samantha", language: "en-US", quality: 1),
            VoiceInfo(id: "au-enh", name: "Karen", language: "en-AU", quality: 2),
            VoiceInfo(id: "gb-enh", name: "Daniel", language: "en-GB", quality: 2),
            VoiceInfo(id: "fr-pre", name: "Thomas", language: "fr-FR", quality: 3),
            VoiceInfo(id: "novelty", name: "Bells", language: "en-US", quality: 3, isNovelty: true),
            VoiceInfo(id: "gb-def", name: "Arthur", language: "en-GB", quality: 1),
        ]
        #expect(VoiceRanking.ranked(voices).map(\.id) == ["au-enh", "gb-enh", "gb-def", "us-def"])
        #expect(VoiceRanking.best(voices)?.id == "au-enh")
    }

    @Test func premiumBeatsAccent() {
        let voices = [
            VoiceInfo(id: "gb-enh", name: "Daniel", language: "en-GB", quality: 2),
            VoiceInfo(id: "us-pre", name: "Zoe", language: "en-US", quality: 3),
        ]
        #expect(VoiceRanking.best(voices)?.id == "us-pre")
    }
}
