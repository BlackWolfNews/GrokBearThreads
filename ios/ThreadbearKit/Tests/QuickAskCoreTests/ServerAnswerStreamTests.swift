import Foundation
import Testing
@testable import QuickAskCore

struct ServerAnswerStreamTests {
    private func feed(_ bytes: some Sequence<UInt8>, into decoder: inout ServerAnswerDecoder) -> [ServerAnswerEvent] {
        bytes.compactMap { decoder.push(byte: $0) }
    }

    @Test func splitLinesAndUTF8WaitForNewline() {
        var decoder = ServerAnswerDecoder(contentType: "Application/X-NDJSON; charset=utf-8")
        let bytes = Array("{\"type\":\"text\",\"text\":\"It’s sunny ☀️.\"}\n".utf8)
        // Each possible chunk boundary includes every position inside the quote and emoji.
        for split in 0...bytes.count {
            var partial = ServerAnswerDecoder(contentType: "application/x-ndjson")
            let a = feed(bytes.prefix(split), into: &partial)
            let b = feed(bytes.dropFirst(split), into: &partial)
            #expect(a + b == [.text("It’s sunny ☀️.")])
        }
        #expect(feed(bytes.dropLast(), into: &decoder).isEmpty)
        #expect(feed([10], into: &decoder) == [.text("It’s sunny ☀️.")])
    }

    @Test func unknownAndMalformedLinesDoNotLoseNextText() {
        var decoder = ServerAnswerDecoder(contentType: "application/x-ndjson")
        let lines = [
            #"{"type":"future","text":"ignored"}"#,
            "not json", #"{"type":"text","text":123}"#,
            #"{"type":"stage","stage":"future"}"#,
            #"{"type":"text","text":"Hello.","future":true}"#,
            #"{"type":"stage","stage":"web","future":true}"#,
            #"{"type":"ping"}"#,
            #"{"type":"done","deep":"future-reason","extra":1}"#,
            #"{"type":"text","text":"after done is ignored"}"#,
        ].joined(separator: "\r\n") + "\r\n"
        #expect(feed(lines.utf8, into: &decoder) == [.text("Hello."), .stage(.web), .ping, .done(deep: "future-reason")])
        #expect(!decoder.wasCutOff)
    }

    @Test func missingDoneAndPartialFinalLineAreCutOff() {
        for end in ["", "{\"type\":\"done\",\"deep\":\"none\"}", "{\"type\":"] {
            var decoder = ServerAnswerDecoder(contentType: "application/x-ndjson")
            #expect(feed(("{\"type\":\"text\",\"text\":\"Hi.\"}\n" + end).utf8, into: &decoder) == [.text("Hi.")])
            #expect(decoder.finish() == nil)
            #expect(decoder.wasCutOff)
        }
    }

    @Test func plainTextFallbackDoesNotWaitForLines() {
        for type in [nil, "text/plain; charset=utf-8", "application/octet-stream"] as [String?] {
            var decoder = ServerAnswerDecoder(contentType: type)
            #expect(!decoder.isNDJSON)
            #expect(feed("H".utf8, into: &decoder) == [.text("H")])
            let rest = feed("i. It’s ☀️.\n".utf8, into: &decoder).compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined()
            #expect("H" + rest == "Hi. It’s ☀️.\n")
            #expect(!decoder.wasCutOff)
        }
    }

    @Test func sourcesMergeWithHeaderAndDedupeByURL() {
        let archive = AnswerSource(title: "Old chat", threadId: "t1", date: "2026-10-24", url: "https://archive.example/t1")
        var decoder = ServerAnswerDecoder(contentType: "application/x-ndjson")
        let line = #"{"type":"sources","sources":[{"kind":"web","title":"Forecast","url":"https://weather.example/perth"},{"kind":"archive","title":"Old chat again","url":"https://archive.example/t1","threadId":"t1","date":"2026-10-24"},{"kind":"web","title":"Bad","url":"javascript:alert(1)"},{"kind":"future","title":"Future","url":"https://future.example"},{"kind":"web","url":"https://missing.example"},null]}"# + "\n"
        let events = feed(line.utf8, into: &decoder)
        guard case .sources(let sources) = events.first else { Issue.record("Missing sources event"); return }
        let merged = AnswerSource.merging(SourcesHeader.decode(SourcesHeader.encode([archive])), sources + sources)
        #expect(merged.count == 2)
        #expect(merged.first == archive)
        #expect(merged.last?.isWeb == true)
        #expect(merged.last?.host == "weather.example")
        #expect(merged.last?.id == "https://weather.example/perth")
    }

    @Test func historyContainsAllTextWithoutStatusOrDivider() throws {
        var decoder = ServerAnswerDecoder(contentType: "application/x-ndjson")
        var progress = AnswerProgress()
        let lines = [
            #"{"type":"text","text":"Checking. "}"#,
            #"{"type":"stage","stage":"web"}"#,
            #"{"type":"text","text":"Quick an"}"#,
            #"{"type":"text","text":"swer. I'll dig deeper. "}"#,
            #"{"type":"stage","stage":"deep"}"#,
            #"{"type":"ping"}"#,
            #"{"type":"text","text":"The deeper answer."}"#,
            #"{"type":"done","deep":"answered"}"#,
        ].joined(separator: "\n") + "\n"
        for event in feed(lines.utf8, into: &decoder) {
            switch event {
            case .text(let text): progress.append(text)
            case .stage(let stage): progress.begin(stage)
            default: break
            }
        }
        #expect(progress.waiting == nil)
        #expect(progress.deepOffset == "Checking. Quick answer. I'll dig deeper. ".count)
        var conversation = Conversation()
        conversation.add(question: "Question?", answer: progress.text)
        let body = AskAPI.body(question: "More?", history: conversation.exchanges, timeZone: .current, now: Date())
        #expect(body.history?.first?.answer == "Checking. Quick answer. I'll dig deeper. The deeper answer.")
    }

    @Test func stagesWaitUntilNonemptyTextAndCanFinishWithoutAny() {
        var progress = AnswerProgress()
        progress.append("☀️ Quick answer. ")
        progress.begin(.deep)
        #expect(progress.waiting == .deep)
        progress.append("")
        #expect(progress.waiting == .deep)
        progress.append("More.")
        #expect(progress.waiting == nil)
        #expect(progress.deepOffset == "☀️ Quick answer. ".count)
        progress.begin(.web)
        progress.finish()
        #expect(progress.waiting == nil)
    }

    @Test func timeoutKeepsInitial30SecondIdleLimit() {
        var deadline = ServerStreamDeadline(startedAt: 100)
        #expect(!deadline.expired(at: 129.99))
        #expect(deadline.expired(at: 130))
        deadline.received(at: 125)
        #expect(!deadline.expired(at: 154.99))
        #expect(deadline.expired(at: 155))
    }

    @Test func stageAllows75TotalWith15BetweenLines() {
        var deadline = ServerStreamDeadline(startedAt: 100)
        deadline.received(at: 101, stage: true)
        #expect(!deadline.expired(at: 115.99))
        #expect(deadline.expired(at: 116))
        // Pings count; they keep a 45-second silent deep stage alive beyond the old 30 s limit.
        for time in stride(from: 106.0, through: 171.0, by: 5) {
            deadline.received(at: time)
            #expect(!deadline.expired(at: time))
        }
        #expect(!deadline.expired(at: 174.99))
        #expect(deadline.expired(at: 175))
    }

    @Test func stageTimingsPersistAndOldTimingsStillDecode() throws {
        var timing = QuestionTiming(trigger: .debug)
        timing.requestSentAt = 10
        timing.endOfSpeechAt = 10
        timing.firstSpokenAt = 11
        timing.firstWebTextAt = 12
        timing.firstDeepTextAt = 52
        var log = TimingLog()
        log.record(timing)
        let decoded = try JSONDecoder().decode(TimingLog.self, from: JSONEncoder().encode(log))
        #expect(decoded.entries.first?.firstWebTextAt == 12)
        #expect(decoded.entries.first?.firstDeepTextAt == 52)
        #expect(timing.breakdown.contains { $0.label == "Request to first web text" && $0.value == "2.00 s" })
        #expect(timing.breakdown.contains { $0.label == "Request to first deep text" && $0.value == "42.00 s" })
        #expect(timing.headline == "1.00 s to first word")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing)) as! [String: Any]
        old.removeValue(forKey: "firstWebTextAt")
        old.removeValue(forKey: "firstDeepTextAt")
        let restored = try JSONDecoder().decode(QuestionTiming.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.firstWebTextAt == nil)
        #expect(restored.firstDeepTextAt == nil)
        #expect(restored.headline == timing.headline)
    }
}

struct HeaderStallTests {
    @Test func noHeadersBySevenSecondsIsAStall() {
        let deadline = ServerStreamDeadline(startedAt: 100)
        #expect(!deadline.stalledBeforeHeaders(at: 106.9, responded: false))
        #expect(deadline.stalledBeforeHeaders(at: 107, responded: false))
        #expect(!deadline.stalledBeforeHeaders(at: 120, responded: true))
    }
}
