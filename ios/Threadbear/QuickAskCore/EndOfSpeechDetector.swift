import Foundation

/// Decides when you've finished asking, from two signals:
///
/// - the mic level: the pause is timed from the last loud buffer, so the wait after you stop
///   talking really is `silence` (700 ms by default), and
/// - the live transcript: its words must also have stopped changing for `wordsSettle`, so a
///   recogniser that's still catching up with your voice doesn't get cut off.
///
/// Only changes to the words count. SFSpeechRecognizer keeps revising punctuation and capitals for
/// a second or so after you stop ("where is paris" becomes "Where is Paris?"), and restarting the
/// wait on each of those is what used to make it about twice the setting.
///
/// "Quiet" is measured against a noise floor that follows the room (it starts at the first buffer's
/// level, drops at once and rises slowly), so steady background noise doesn't count as speech. If
/// noise does keep the level up, the transcript alone ends it after `silence × noisyMultiplier`. If
/// the level never heard you (or missed the end, words turning up long after the last loud buffer),
/// the transcript alone ends it after `silence`.
///
/// Times are seconds on any one clock; the app uses `Date().timeIntervalSince1970`.
nonisolated struct EndOfSpeechDetector {
    struct Config: Equatable, Sendable {
        var silence: TimeInterval = 0.7
        /// How long the words must also have gone unchanged. The recogniser reports the last word
        /// a few hundred ms after it's said, so this is usually over before the silence is.
        var wordsSettle: TimeInterval = 0.35
        /// Words reported more than this long after the last loud buffer mean the level missed
        /// some speech (a quiet voice), so the transcript decides on its own.
        var recogniserLag: TimeInterval = 1
        /// The pause needed when the words so far stop on one a question can't end on ("which
        /// direction did I take the…"): long enough to look for the next word without ending the
        /// question under you. On the phone on 24 October a 700 ms pause cut off a question there.
        var midSentenceSilence: TimeInterval = 1.5
        /// With a noisy level, the transcript alone ends it after silence × this.
        var noisyMultiplier: Double = 2
        /// Speech is at least this far above the noise floor...
        var speechMarginDB: Float = 10
        /// ...and above this, however quiet the room.
        var minimumSpeechDB: Float = -55
        /// How quickly the noise floor creeps up during sound (it falls immediately).
        var floorRiseSeconds: TimeInterval = 3

        init(silence: TimeInterval = 0.7) {
            self.silence = silence
            wordsSettle = min(0.35, silence / 2)
        }
    }

    let config: Config
    /// The latest transcript, punctuation and all (it's what gets sent).
    private(set) var transcript = ""
    /// The transcript's words, as `words(in:)` sees them.
    private(set) var words: [String] = []
    /// The last change that added, removed or altered a word.
    private(set) var lastWordChangeAt: TimeInterval?
    /// The last change of any kind, punctuation and capitals included (for the log).
    private(set) var lastTranscriptChangeAt: TimeInterval?
    /// Changes that only touched punctuation or capitals, which don't restart the wait.
    private(set) var revisionsIgnored = 0
    private(set) var lastSpeechAudioAt: TimeInterval?
    private(set) var noiseFloorDB: Float = -60
    private var lastLevelAt: TimeInterval?

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func transcriptChanged(_ text: String, at time: TimeInterval) {
        guard text != transcript else { return }
        transcript = text
        lastTranscriptChangeAt = time
        let next = Self.words(in: text)
        if next == words, lastWordChangeAt != nil {
            revisionsIgnored += 1
            return
        }
        words = next
        lastWordChangeAt = time
    }

    /// `db` is the buffer's RMS level in dBFS (0 is full scale, silence is around -80 or below).
    mutating func audioLevel(_ db: Float, at time: TimeInterval) {
        guard let previous = lastLevelAt else {
            // The first buffer arrives before anyone can start talking, so it's the room.
            lastLevelAt = time
            noiseFloorDB = min(max(db, -90), -30)
            return
        }
        let elapsed = max(0, time - previous)
        lastLevelAt = time
        if db < noiseFloorDB {
            noiseFloorDB = max(db, -90)
        } else {
            let alpha = Float(1 - exp(-elapsed / config.floorRiseSeconds))
            noiseFloorDB = min(noiseFloorDB + (db - noiseFloorDB) * alpha, -20)
        }
        if isSpeech(db) { lastSpeechAudioAt = time }
    }

    func isSpeech(_ db: Float) -> Bool {
        db >= max(noiseFloorDB + config.speechMarginDB, config.minimumSpeechDB)
    }

    /// Time to send: you've been quiet for the whole silence setting and the recogniser has stopped
    /// adding words. nil while you're still talking (or haven't said anything worth sending);
    /// otherwise the best guess at when you stopped.
    func endOfSpeech(at now: TimeInterval) -> TimeInterval? {
        pause(at: now, lasting: config.silence, wordsStillFor: config.wordsSettle)
    }

    /// When you stopped talking, once the level has been quiet for `pause` and the words still for
    /// `settle`. nil until then. `endOfSpeech` is this with the silence setting; `EarlySend` uses a
    /// shorter pause.
    func pause(at now: TimeInterval, lasting pause: TimeInterval, wordsStillFor settle: TimeInterval) -> TimeInterval? {
        guard Self.isMeaningful(transcript), let wordsAt = lastWordChangeAt else { return nil }
        // Stopped mid-sentence: wait longer, for the end of the question and for sending it early
        // alike, since an early request for half a question would only be thrown away.
        let pause = Self.endsMidSentence(words) ? max(pause, config.midSentenceSilence) : pause
        let wordsStill = now - wordsAt
        // The level knows when you actually stopped, as long as it heard you up to about when the
        // last words came in.
        if let spokeAt = lastSpeechAudioAt, wordsAt - spokeAt <= config.recogniserLag {
            let quietFor = now - spokeAt
            if quietFor >= pause, wordsStill >= settle { return min(spokeAt, now) }
            // Noise is keeping the level up (it was loud within the last half pause), but there are
            // no new words: the transcript alone, after longer. If the level's been quiet for a
            // while it's on its way to the whole pause, so that's waited for instead.
            if quietFor < pause / 2, wordsStill >= pause * config.noisyMultiplier { return wordsAt }
            return nil
        }
        return wordsStill >= pause ? wordsAt : nil
    }

    /// Fewer than three letters, or only filler words, isn't a question.
    static func isMeaningful(_ transcript: String) -> Bool {
        let words = words(in: transcript)
        let letters = words.joined().count
        guard letters >= 3 else { return false }
        return !words.allSatisfy { fillers.contains($0) }
    }

    /// The words alone: lowercased, with punctuation dropped and apostrophes closed up, so "What's
    /// the T3-code?" and "whats the t3 code" are the same words. What the recogniser revises after
    /// a pause is mostly these, not the words.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    /// Whether the last word is one a question can't end on, so you're probably still going: an
    /// article, a possessive, a joining word, or a filler. Kept short on purpose. Plenty of
    /// questions end on a preposition ("what was I working on", "who was I talking to"), and each
    /// word here costs those that end on it the longer pause.
    static func endsMidSentence(_ words: [String]) -> Bool {
        guard let last = words.last else { return false }
        return midSentenceWords.contains(last) || fillers.contains(last)
    }

    private static let midSentenceWords: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "his", "her", "its", "and", "or", "but", "of",
    ]

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "oh"]
}
