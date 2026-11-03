import AVFoundation
import Observation
import Speech
import os

/// Tap the mic, talk, and the words land in the new thread's text box.
/// On-device SFSpeechRecognizer where the phone has the model, Apple's
/// servers if it won't start, as Quick Ask does (ClassicTranscriber). It
/// never sends on its own: a new thread is worth a glance before it goes.
///
/// Dropped on 31 Oct because what had been said got wiped, and back on
/// 3 Nov for new threads only (Mike wanted the button). The wipe was the
/// recognizer starting its transcript over after a pause, so `Carry` keeps
/// what came before a restart rather than trusting the latest result alone.
@MainActor @Observable
final class Dictation {
    private(set) var isListening = false
    private(set) var problem: String?

    private let log = Logger(subsystem: "com.mikecann.threadbear", category: "speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale.current.language.languageCode?.identifier == "en" ? .current : Locale(identifier: "en-GB"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onDeviceBroken = false
    private var generation = 0
    /// Whether start has touched the audio session and mic, so stop has something to undo.
    private var holdsAudio = false
    private var carry = Carry()

    /// `onText` gets the whole transcript so far, every time it changes.
    func start(onText: @escaping (String) -> Void) async {
        problem = nil
        guard await Self.permission() else {
            problem = "Turn on the microphone and speech recognition for Threadbear in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        stop()
        generation += 1
        let current = generation
        holdsAudio = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition && !onDeviceBroken
            self.request = request
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            // The tap runs on the audio queue. Written plainly inside this
            // @MainActor class the block would be main-actor isolated (the
            // project's default isolation), and iOS 18 trapped on the first
            // buffer: dispatch_assert_queue in Dictation.start. So it's
            // @Sendable and reaches the request through MicSink.
            let sink = MicSink(request)
            // MicTap refuses while the mic's format is still settling after
            // the category change, for a few tens of milliseconds: try again.
            var refusal: MicTap.Refusal?
            for attempt in 0..<20 {
                do {
                    try MicTap.install(on: input) { buffer, _ in sink.append(buffer) }
                    refusal = nil
                    break
                } catch {
                    refusal = error
                    guard error == .formatChanging, attempt < 19 else { break }
                    try await Task.sleep(for: .milliseconds(50))
                    guard generation == current else { return }
                }
            }
            if let refusal {
                problem = refusal == .noMicrophone ? "There's no microphone available." : "Couldn't start the microphone. Tap the mic to try again."
                stop()
                return
            }
            engine.prepare()
            try engine.start()
            isListening = true
            carry = Carry()
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let nsError = error as NSError?
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if let text { onText(self.carry.add(text)) }
                    guard let nsError, !Self.isBenign(nsError) else { return }
                    if request.requiresOnDeviceRecognition, nsError.domain == "kLSRErrorDomain", [100, 101, 102, 300].contains(nsError.code) {
                        self.log.error("On-device recognition wouldn't start (\(nsError.code)); using the server")
                        self.onDeviceBroken = true
                        self.stop()
                        await self.start(onText: onText)
                        return
                    }
                    self.log.error("Recognition error \(nsError.domain, privacy: .public) \(nsError.code)")
                    self.problem = "Speech recognition stopped. Tap the mic to try again."
                    self.stop()
                }
            }
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        generation += 1
        // Every send and every closed thread lands here, mic used or not. Going
        // on would make the engine's input node, which sets up the mic hardware,
        // and deactivate a session we never took, all while another app may be
        // playing: Mike's podcast paused for a moment on each send (31 Oct).
        guard holdsAudio else { return }
        holdsAudio = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// "No speech detected" and cancellation aren't worth showing.
    private static func isBenign(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain" && [203, 209, 216, 301, 1110].contains(error.code)
    }

    private static func permission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await requestSpeech()
        }
        return AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    nonisolated private static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// The transcript across the recognizer's restarts. Each result is meant to be
/// the whole transcript so far, but after a pause iOS can begin again from the
/// new words alone. When a result is shorter than the last and doesn't begin
/// the same way, the last is kept and the new words go after it.
nonisolated struct Carry {
    private var kept = ""
    private var last = ""

    mutating func add(_ text: String) -> String {
        if !last.isEmpty, text.count < last.count, Self.firstWord(text) != Self.firstWord(last) {
            kept = Self.join(kept, last)
        }
        last = text
        return Self.join(kept, text)
    }

    private static func firstWord(_ text: String) -> String {
        String(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first ?? "")
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

/// Carries the mic's buffers from the audio thread to the recognition request.
/// `append` on a request is thread-safe; the box exists so the tap block can
/// be @Sendable without capturing the (non-Sendable) request itself.
nonisolated private final class MicSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
