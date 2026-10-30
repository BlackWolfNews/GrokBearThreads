import AVFoundation
import Observation
import Speech
import os

/// Tap the mic, talk, and the words land in the text box. On-device
/// SFSpeechRecognizer where the phone has the model, Apple's servers if it
/// won't start, as Quick Ask does (ClassicTranscriber). It never sends on its
/// own: an agent reply is worth a glance before it goes.
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
            // Just after the category changes (from Ask's playAndRecord, or
            // a call) the node can still report the old format, and a tap
            // in a format the hardware isn't running at is an Objective-C
            // exception Swift can't catch: it crashed the app on 30 Oct, as
            // it had Ask on 29 Oct (AudioInput.installTapIfNeeded). So wait
            // for it to settle, which takes a few tens of milliseconds.
            var settled = false
            for _ in 0..<20 {
                if Self.formatSettled(input) { settled = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard generation == current else { return }
            guard settled else {
                problem = "Couldn't start the microphone. Tap the mic to try again."
                stop()
                return
            }
            // The tap runs on the audio queue. Written plainly inside this
            // @MainActor class the block would be main-actor isolated (the
            // project's default isolation), and iOS 18 trapped on the first
            // buffer: dispatch_assert_queue in Dictation.start. So it's
            // @Sendable and reaches the request through MicSink.
            let sink = MicSink(request)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
                sink.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let nsError = error as NSError?
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if let text { onText(text) }
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
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Whether the mic node's format is one a tap can be put on: a real
    /// microphone, at the rate the hardware is running.
    private static func formatSettled(_ input: AVAudioInputNode) -> Bool {
        let format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 && hardware.sampleRate == format.sampleRate
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

/// Carries the mic's buffers from the audio thread to the recognition request.
/// `append` on a request is thread-safe; the box exists so the tap block can
/// be @Sendable without capturing the (non-Sendable) request itself.
nonisolated private final class MicSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
