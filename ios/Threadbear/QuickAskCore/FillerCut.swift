import Foundation

/// When the server can't answer from the archive, it says a filler line ("That's not in the
/// archive, so I'm checking the web.") while it searches, and the web answer's often ready before
/// that's been said. This decides when to cut the filler short, so the answer's heard straight away.
///
/// The filler is everything said before the answer's first stage line. When the first sentence
/// after that stage is ready and some of the filler is still to be said, the filler's stopped at
/// the end of the word it's on, and the answer's sentences are held until the synthesizer reports
/// that it's stopped. Nothing after a stage line is ever cut: the quick web answer and "I'll dig a
/// bit deeper." play out in full when the deeper answer arrives.
///
/// Why it's always the end of a word, and why the answer waits: stopping clears the synthesizer's
/// whole queue, and in the simulator a sentence queued just after stopping straight away (rather
/// than at a word) sometimes came out with no words reported and in about half the time it takes
/// to say, when the voice wasn't warm yet. That happened even after waiting for the stopped
/// sentence to report back. Stopping at a word never did that, so a filler that hasn't started yet
/// gets its first word said too ("That's", about 130 ms) rather than being dropped.
///
/// Speaker tells it what's to be said and what the synthesizer reports, and does the steps it
/// returns. Sentences are numbered from 0 in the order they're given. Times are Stopwatch seconds.
nonisolated struct FillerCut: Sendable {
    enum Boundary: Equatable, Sendable {
        case word, immediate
    }

    enum Step: Equatable, Sendable {
        /// Queue this sentence on the synthesizer.
        case speak(id: Int, text: String)
        /// Stop the filler: at the end of the word it's on, or straight away if that never reports.
        case stop(Boundary)
        /// Call `waitRanOut` after this many seconds, unless `stopped` comes first.
        case waitAtMost(Double)
        /// The filler's stopped (or the wait for it ran out); the held sentences follow.
        case stopped
    }

    /// How the cut went, for the log.
    struct Cut: Equatable, Sendable {
        let at: Double
        /// How long the filler had been speaking when the answer was ready; nil if it hadn't started.
        let spokenFor: Double?
        var stoppedAt: Double?
        /// It said it had stopped while the synthesizer was still speaking.
        var stillSpeaking = false
        /// The synthesizer never said it had stopped (or never went quiet), so it was stopped
        /// straight away.
        var timedOut = false
        /// How many of the answer's sentences were waiting when it stopped.
        var released = 0
    }

    /// The longest a word took to stop in the simulator was 0.7 s ("archive," and the pause after
    /// its comma), and a first word with the voice not yet warm 0.5 s; this leaves room for a
    /// slower voice. Only reached if the synthesizer never reports back.
    static let wordStopWait: Double = 1.2
    /// When the stopped sentence has reported back but the synthesizer's still speaking. A short
    /// first word ("So") took about 110 ms to stop in the simulator.
    static let nextSentenceWait: Double = 0.3
    /// After stopping straight away, before the answer's queued, so it isn't queued on a stop
    /// that's still going.
    static let settleWait: Double = 0.3

    private(set) var cut: Cut?
    private var nextID = 0
    private var sawStage = false
    /// The first sentence after the stage has been given, so there's nothing more to decide.
    private var answerStarted = false
    private var filler: Set<Int> = []
    /// Given to the synthesizer, and expected to be reported finished.
    private var queued: Set<Int> = []
    private var fillerStartedAt: Double?
    /// The filler sentences the cut stopped, which the synthesizer may still report on. Those
    /// queued behind the one speaking are dropped without a word, and aren't reported at all.
    private var stopping: Set<Int> = []
    /// The wait ran out and it was stopped straight away; now it's only waiting for that to settle.
    private var forced = false
    private var held: [(id: Int, text: String)] = []

    /// Nothing's being said or waiting to be.
    var isIdle: Bool { queued.isEmpty && held.isEmpty }

    var isCutting: Bool { cut != nil && cut?.stoppedAt == nil }

    // MARK: - What's to be said

    /// A stage line arrived. Everything said from now on is the answer; only the first one counts.
    mutating func stageBegan() {
        sawStage = true
    }

    /// The next sentence to say.
    mutating func sentence(_ text: String, at now: Double) -> [Step] {
        let id = nextID
        nextID += 1
        if !sawStage {
            filler.insert(id)
            return [enqueue(id, text)]
        }
        if isCutting {
            held.append((id, text))
            return []
        }
        guard !answerStarted else { return [enqueue(id, text)] }
        answerStarted = true
        let left = queued.intersection(filler)
        // The filler's been said already (or there wasn't one): nothing changes.
        guard !left.isEmpty else { return [enqueue(id, text)] }

        cut = Cut(at: now, spokenFor: fillerStartedAt.map { now - $0 })
        stopping = left
        // Only the stopped ones can still report back, so they no longer count as queued.
        queued.subtract(left)
        held = [(id, text)]
        return [.stop(.word), .waitAtMost(Self.wordStopWait)]
    }

    // MARK: - What the synthesizer reports

    mutating func started(_ id: Int, at now: Double) {
        if filler.contains(id), fillerStartedAt == nil { fillerStartedAt = now }
    }

    /// The synthesizer finished or cancelled a sentence (stopping at a word is reported as
    /// finishing). `quiet` is whether it's stopped speaking altogether.
    mutating func finished(_ id: Int, quiet: Bool, at now: Double) -> [Step] {
        queued.remove(id)
        guard isCutting, stopping.remove(id) != nil, !forced else { return [] }
        if quiet { return release(at: now) }
        cut?.stillSpeaking = true
        // Still speaking: the filler's next sentence started just as the cut was made (its start
        // hadn't been reported yet), and it stops after its first word. Not worth the whole wait.
        return [.waitAtMost(Self.nextSentenceWait)]
    }

    /// The synthesizer didn't say it had stopped in time: stop straight away, give that a moment,
    /// then go on.
    mutating func waitRanOut(at now: Double) -> [Step] {
        guard isCutting else { return [] }
        guard forced else {
            forced = true
            cut?.timedOut = true
            return [.stop(.immediate), .waitAtMost(Self.settleWait)]
        }
        return release(at: now)
    }

    /// Everything was stopped (a tap, a new question). Sentences from before this are ignored if
    /// they're reported on later, since their numbers aren't used again.
    mutating func reset() {
        let next = nextID
        self = FillerCut()
        nextID = next
    }

    // MARK: -

    private mutating func enqueue(_ id: Int, _ text: String) -> Step {
        queued.insert(id)
        return .speak(id: id, text: text)
    }

    private mutating func release(at now: Double) -> [Step] {
        cut?.stoppedAt = now
        cut?.released = held.count
        stopping.removeAll()
        let waiting = held
        held.removeAll()
        return [.stopped] + waiting.map { enqueue($0.id, $0.text) }
    }
}
