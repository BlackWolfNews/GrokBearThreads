import AppKit
import Observation
import ThreadbearCore

/// Voice mode: talking with a thread out loud. It's another way in and
/// out of the same thread, not another agent: what Mike says is sent as
/// his message (into the running turn if there is one, as typing during a
/// turn is), and the agent's replies are read out. So the thread keeps its
/// memory, tools and approvals, and goes on working while he talks.
/// Talking over the agent stops it speaking. One thread at a time.
@MainActor
@Observable
final class VoiceMode {
    static let shared = VoiceMode()

    enum Phase: Equatable {
        case off
        /// Downloading or starting the engine, or asking for the microphone.
        case starting(String)
        case listening
        /// He's talking: the words so far.
        case hearing(String)
        /// Sent; the agent is working on it.
        case thinking
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var threadId: String?
    /// 0...1: him while listening, the agent while it speaks.
    private(set) var level: Float = 0

    @ObservationIgnored private var audio: VoiceAudio?
    @ObservationIgnored private var tracker = UtteranceTracker(pause: 1.0)
    @ObservationIgnored private var endpointTimer: Timer?
    @ObservationIgnored private var base: URL?
    /// Replies already spoken, so a catch-up doesn't say one twice.
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var startedAt = Date()
    /// The agent's turn is running.
    @ObservationIgnored private var working = false
    /// The turn's newest message, said when it ends unless a final reply came.
    @ObservationIgnored private var lastMessage: (String, String, String)?

    var isOn: Bool { phase != .off }

    func isOn(for threadId: String) -> Bool { isOn && self.threadId == threadId }

    func toggle(threadId: String) {
        if isOn(for: threadId) { stop() } else { start(threadId: threadId) }
    }

    func start(threadId: String) {
        stop()
        self.threadId = threadId
        startedAt = Date()
        phase = .starting("Getting ready…")
        let defaults = UserDefaults.standard
        let language = VoiceCatalog.language(defaults.string(forKey: VoiceCatalog.languageKey))
        let mic = VoiceAudio.microphone(uid: defaults.string(forKey: VoiceCatalog.microphoneKey))
        VoiceServer.shared.onStatus = { [weak self] status in
            if case .starting = self?.phase { self?.phase = .starting(status) }
        }
        Task {
            do {
                let base = try await VoiceServer.shared.ready(language: language.id)
                guard self.threadId == threadId else { return }
                self.base = base
                let audio = VoiceAudio()
                audio.onResult = { [weak self] in self?.heard($0) }
                audio.onInputLevel = { [weak self] level in
                    guard let self, !(self.audio?.isSpeaking ?? false) else { return }
                    self.level = level
                }
                audio.onOutputLevel = { [weak self] level in
                    guard let self, self.audio?.isSpeaking ?? false else { return }
                    self.level = level
                }
                audio.onSpeaking = { [weak self] on in
                    guard let self, self.isOn else { return }
                    if on { self.phase = .speaking } else if case .speaking = self.phase { self.phase = self.working ? .thinking : .listening }
                }
                self.audio = audio
                self.phase = .starting("Asking for the microphone…")
                try await audio.start(locale: Locale(identifier: language.locale), microphone: mic)
                guard self.threadId == threadId else { audio.stop(); return }
                self.phase = .listening
                self.endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkPause() }
                }
                AppLog.write("voice", "on for \(threadId)")
            } catch {
                guard self.threadId == threadId else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isOn || audio != nil else { return }
        if let threadId, let text = tracker.flush() { send(text, to: threadId) }
        endpointTimer?.invalidate()
        endpointTimer = nil
        audio?.stop()
        audio = nil
        tracker = UtteranceTracker(pause: 1.0)
        phase = .off
        level = 0
        working = false
        if let threadId { AppLog.write("voice", "off for \(threadId)") }
        threadId = nil
        VoiceServer.shared.stopSoon()
    }

    private func fail(_ message: String) {
        AppLog.write("voice", "failed: \(message)")
        endpointTimer?.invalidate()
        endpointTimer = nil
        audio?.stop()
        audio = nil
        phase = .failed(message)
    }

    /// The error under the composer goes when he closes it.
    func dismissFailure() {
        if case .failed = phase { phase = .off; threadId = nil }
    }

    // MARK: Hearing him

    private func heard(_ result: UtteranceTracker.Result) {
        guard isOn else { return }
        if tracker.add(result, now: CACurrentMediaTime()) {
            // He's talking: the agent stops.
            if audio?.isSpeaking == true { audio?.stopSpeaking() }
            phase = .hearing(tracker.pending)
        }
    }

    private func checkPause() {
        guard let threadId, let text = tracker.take(now: CACurrentMediaTime()) else { return }
        send(text, to: threadId)
    }

    private func send(_ text: String, to threadId: String) {
        AppModel.shared.sendSpoken(threadId: threadId, text: text)
        working = true
        phase = .thinking
    }

    // MARK: The agent's side

    /// Every live event of the voice thread (ThreadSession.receive).
    func receive(_ event: Event) {
        guard isOn, event.threadId == threadId else { return }
        switch event.payload {
        case .turnStarted:
            working = true
            lastMessage = nil
            if case .listening = phase { phase = .thinking }
        case .turnCompleted:
            working = false
            // A thread without one reply: its last message was the reply.
            if let (id, text, ts) = lastMessage { say(text, id: id, at: ts) }
            lastMessage = nil
            if case .thinking = phase { phase = .listening }
        case .assistantText(let itemId, let text, let summary, let narration, _, let final):
            guard !summary, !narration else { return }
            if final {
                // One reply's message after end_turn: the reply, said now.
                lastMessage = nil
                say(text, id: itemId, at: event.ts)
            } else {
                lastMessage = (itemId, text, event.ts)
            }
        case .approvalRequested(let request):
            say("I need your OK on screen: \(request.title).", id: "approval-\(event.seq)", at: event.ts)
        case .questionRequested:
            say("I've got a question for you on screen.", id: "question-\(event.seq)", at: event.ts)
        default:
            break
        }
    }

    private func say(_ markdown: String, id: String, at ts: String) {
        // Only what came after Voice was turned on.
        if let date = ISO8601DateFormatter.withFractions.date(from: ts) ?? ISO8601DateFormatter().date(from: ts), date < startedAt { return }
        guard spoken.insert(id).inserted, let audio, let base else { return }
        let defaults = UserDefaults.standard
        let voice = VoiceCatalog.voice(defaults.string(forKey: VoiceCatalog.voiceKey))
        let speed = VoiceCatalog.speed(defaults.object(forKey: VoiceCatalog.speedKey) as? Double)
        audio.speak(SpokenText.sentences(markdown), voice: voice.engineVoice, speed: speed, base: base)
    }

    // MARK: Settings' Try button

    @ObservationIgnored private var previewAudio: VoiceAudio?
    private(set) var previewStatus: String?

    func preview(voice: VoiceOption, speed: Double) {
        let language = VoiceCatalog.language(UserDefaults.standard.string(forKey: VoiceCatalog.languageKey))
        previewStatus = "Getting the voice ready…"
        VoiceServer.shared.onStatus = { [weak self] in self?.previewStatus = $0 }
        Task {
            do {
                let base = try await VoiceServer.shared.ready(language: language.id)
                let audio = previewAudio ?? VoiceAudio()
                previewAudio = audio
                try audio.preview("Hi, I'm \(voice.name). Ask me anything, and I'll keep working while we talk.", voice: voice.engineVoice, speed: speed, base: base)
                previewStatus = nil
                VoiceServer.shared.stopSoon()
            } catch {
                previewStatus = error.localizedDescription
            }
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
