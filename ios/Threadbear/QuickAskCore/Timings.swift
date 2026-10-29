import Foundation

/// Every moment worth timing for one question, as seconds since 1970. The durations Mike tunes by
/// are worked out from these, so a missing moment just leaves its duration out.
nonisolated struct QuestionTiming: Codable, Equatable, Identifiable, Sendable {
    enum Trigger: String, Codable, Sendable {
        /// Cold launch (from the Action button, Siri, a control or the icon)
        case launch
        /// The Ask intent ran while the app was already running
        case intent
        /// Came back to the app from the background
        case resume
        /// The mic button
        case followUp
        /// A debug question from the launch arguments
        case debug

        var label: String {
            switch self {
            case .launch: "Launch"
            case .intent: "Ask shortcut"
            case .resume: "Reopened"
            case .followUp: "Follow-up"
            case .debug: "Debug question"
            }
        }
    }

    var id = UUID()
    var trigger: Trigger
    var question = ""
    var transcriber = ""
    var spoke = true

    /// The press, as near as the app can tell: process start on a cold launch, else when the intent
    /// ran or the app came to the front.
    var pressAt: TimeInterval?
    /// The first audio buffer arrived.
    var micLiveAt: TimeInterval?
    /// When you stopped talking (the detector's estimate), or the tap that sent it.
    var endOfSpeechAt: TimeInterval?
    /// When it was decided to send the request that answered: the short pause it went early at
    /// (see `EarlySend`), else the full pause running out, or the tap.
    var sendDecidedAt: TimeInterval?
    /// The full pause ran out (or the tap): from here the answer can be shown and spoken. After
    /// `requestSentAt` when the question went early. nil in timings from before early sending.
    var pauseEndedAt: TimeInterval?
    var requestSentAt: TimeInterval?
    /// Status and headers arrived.
    var responseAt: TimeInterval?
    var firstByteAt: TimeInterval?
    var firstWebTextAt: TimeInterval?
    var firstDeepTextAt: TimeInterval?
    var firstSpokenAt: TimeInterval?
    var completeAt: TimeInterval?
    var serverTiming: [ServerTimingEntry] = []

    init(trigger: Trigger, pressAt: TimeInterval? = nil) {
        self.trigger = trigger
        self.pressAt = pressAt
    }

    var date: Date { Date(timeIntervalSince1970: pressAt ?? sendDecidedAt ?? requestSentAt ?? 0) }

    // MARK: - Durations, in milliseconds

    var pressToMic: Double? { Self.ms(pressAt, micLiveAt) }
    var endToRequest: Double? { Self.ms(endOfSpeechAt, requestSentAt) }
    /// The part of endToRequest spent waiting for a pause (the short one, if it went early).
    var silenceWait: Double? { Self.ms(endOfSpeechAt, sendDecidedAt) }
    /// The whole wait for the pause, which is what the "Send after a pause of" setting sets.
    var fullPause: Double? { Self.ms(endOfSpeechAt, pauseEndedAt ?? sendDecidedAt) }
    var requestToFirstByte: Double? { Self.ms(requestSentAt, firstByteAt) }
    /// The request went out before the full pause had run out.
    var sentEarly: Bool {
        guard let requestSentAt, let pauseEndedAt else { return false }
        return requestSentAt < pauseEndedAt
    }
    /// The part of requestToFirstByte that went by while still waiting out the pause, so cost
    /// nothing: how much sooner the answer came than if it had been sent at the end of the pause.
    var hiddenByEarlySend: Double? {
        guard sentEarly, let pauseEndedAt else { return nil }
        return Self.ms(requestSentAt, min(pauseEndedAt, firstByteAt ?? pauseEndedAt))
    }
    /// From the first byte, or the end of the pause if the answer was already arriving by then,
    /// to the first word.
    var firstByteToFirstWord: Double? { Self.ms(answerShownAt, firstWordAt) }
    /// The headline: from when you stopped talking to the first word you hear (or see, with
    /// speaking turned off).
    var endToFirstWord: Double? { Self.ms(endOfSpeechAt, firstWordAt) }
    var streamDuration: Double? { Self.ms(firstByteAt, completeAt) }

    /// An answer that arrives during the pause is held back until the pause has run out.
    private var answerShownAt: TimeInterval? {
        guard let firstByteAt else { return nil }
        return max(firstByteAt, pauseEndedAt ?? firstByteAt)
    }

    private var firstWordAt: TimeInterval? { spoke ? firstSpokenAt : answerShownAt }

    static func ms(_ start: TimeInterval?, _ end: TimeInterval?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, (end - start) * 1000)
    }

    // MARK: - Words

    var headline: String? {
        guard let total = endToFirstWord else { return nil }
        return "\(TimingFormat.duration(total)) to first \(spoke ? "word" : "text")"
    }

    /// The breakdown under the headline, in order.
    var breakdown: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: Double?) {
            if let value { rows.append((label, TimingFormat.duration(value))) }
        }
        add(trigger == .followUp ? "Mic button to mic live" : "Press to mic live", pressToMic)
        add("End of speech to request sent", endToRequest)
        add("  of which waiting for silence", silenceWait)
        if sentEarly { add("End of speech to end of pause", fullPause) }
        add("Request to first byte", requestToFirstByte)
        // Filtered here too, for timings saved before Cloudflare's entries were dropped on arrival.
        let server = ServerTiming.ours(serverTiming)
        if !server.isEmpty { rows.append(("  server", TimingFormat.server(server))) }
        add("  of which hidden behind the pause", hiddenByEarlySend)
        add(spoke ? "First byte to first spoken word" : "First byte to first text", firstByteToFirstWord)
        add(spoke ? "End of speech to first spoken word" : "End of speech to first text", endToFirstWord)
        add("Request to first web text", Self.ms(requestSentAt, firstWebTextAt))
        add("Request to first deep text", Self.ms(requestSentAt, firstDeepTextAt))
        add("Whole answer streamed in", streamDuration)
        return rows
    }
}

nonisolated enum TimingFormat {
    /// "84 ms", "1.24 s"
    static func duration(_ ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.2f s", ms / 1000)
    }

    /// "auth 12 ms, retrieve 340 ms"
    static func server(_ entries: [ServerTimingEntry]) -> String {
        entries.map { entry in
            entry.durationMs.map { "\(entry.name) \(duration($0))" } ?? entry.name
        }
        .joined(separator: ", ")
    }
}

/// The most recent timings, newest first.
nonisolated struct TimingLog: Codable, Equatable, Sendable {
    static let limit = 20
    private(set) var entries: [QuestionTiming] = []

    /// Adds a timing, or replaces it if it's already there (it's saved again as more arrives).
    mutating func record(_ timing: QuestionTiming) {
        if let index = entries.firstIndex(where: { $0.id == timing.id }) {
            entries[index] = timing
        } else {
            entries.insert(timing, at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
    }

    mutating func clear() { entries.removeAll() }

    /// The middle of the last few headline numbers, which is steadier to tune by than any one.
    var medianEndToFirstWord: Double? {
        let values = entries.compactMap(\.endToFirstWord).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}
