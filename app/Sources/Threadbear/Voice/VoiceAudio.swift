import AVFoundation
import CoreAudio
import Speech
import ThreadbearCore

/// The microphone and the speaker for Voice mode, on one audio engine with
/// the Mac's voice processing on, so its echo cancellation keeps the agent
/// from hearing itself and Mike can talk over it. What he says goes to
/// Apple's on-device speech recognition (SpeechAnalyzer); what the agent
/// says comes from pocket-tts as 24 kHz 16-bit WAV, a sentence at a time.
@MainActor
final class VoiceAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var queued = 0
    private var speakId: UUID?

    /// A result from the recogniser (text, audio seconds, final or not).
    var onResult: ((UtteranceTracker.Result) -> Void)?
    /// How loud he is (0...1), for the button and the avatar.
    var onInputLevel: ((Float) -> Void)?
    /// How loud the agent is (0...1) while it speaks.
    var onOutputLevel: ((Float) -> Void)?
    /// Speaking started (true) or everything queued has been said (false).
    var onSpeaking: ((Bool) -> Void)?

    private(set) var isSpeaking = false

    // MARK: Listening

    func start(locale: Locale, microphone: AudioDeviceID?) async throws {
        try await Self.askForAccess()
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError("Speech recognition doesn't support \(locale.identifier) on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError("Speech recognition has no audio format to use.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let range = result.range
                    let r = UtteranceTracker.Result(text: text, start: range.start.seconds.finite, end: range.end.seconds.finite, isFinal: result.isFinal)
                    self?.onResult?(r)
                }
            } catch {
                AppLog.write("voice", "recogniser stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)

        if let microphone { Self.use(microphone, on: engine.inputNode) }
        try engine.inputNode.setVoiceProcessingEnabled(true)
        // Its ducking of other audio is for calls; a reply shouldn't hush music any more than it must.
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: speechFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: speechFormat)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        // Made here and captured, as the tap runs on the audio thread.
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceError("The microphone's audio can't be read for speech recognition.")
        }
        let feed = continuation
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.level(buffer)
            if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                feed.yield(AnalyzerInput(buffer: converted))
            }
            Task { @MainActor in self?.onInputLevel?(level) }
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        stopSpeaking()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    // MARK: Speaking

    /// Says the sentences in order, in `voice` at `speed`, from the server at `base`.
    func speak(_ sentences: [String], voice: String, speed: Double, base: URL) {
        guard !sentences.isEmpty else { return }
        pitch.rate = Float(speed)
        let previous = speakTask
        let id = UUID()
        speakId = id
        speakTask = Task { [weak self] in
            await previous?.value
            for sentence in sentences {
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.stream(sentence, voice: voice, base: base)
                } catch {
                    if !Task.isCancelled { AppLog.write("voice", "couldn't speak: \(error.localizedDescription)") }
                    break
                }
            }
            // Everything's been fetched; once it's played, it's said.
            guard let self, self.speakId == id else { return }
            self.speakTask = nil
            if self.queued == 0 { self.setSpeaking(false) }
        }
    }

    /// Stops talking now: he's started speaking, or Voice was turned off.
    func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        player.stop()
        if engine.isRunning { player.play() }
        queued = 0
        setSpeaking(false)
    }

    private func stream(_ text: String, voice: String, base: URL) async throws {
        var request = URLRequest(url: base.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        let boundary = "tb-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["text": text, "voice_url": voice], boundary: boundary)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("the voice engine said \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        var wav = WAVStream()
        var chunk = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            // About a tenth of a second at a time.
            if chunk.count >= 4800 {
                schedule(wav.samples(from: chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { schedule(wav.samples(from: chunk)) }
    }

    private func schedule(_ samples: [Int16]) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let out = buffer.floatChannelData![0]
        var peak: Float = 0
        for (i, s) in samples.enumerated() {
            let v = Float(s) / 32768
            out[i] = v
            peak = max(peak, abs(v))
        }
        queued += 1
        setSpeaking(true)
        onOutputLevel?(min(1, peak * 1.4))
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.queued = max(0, self.queued - 1)
                self.onOutputLevel?(self.queued == 0 ? 0 : min(1, peak * 1.4))
                if self.queued == 0, self.speakTask == nil { self.setSpeaking(false) }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func setSpeaking(_ on: Bool) {
        guard isSpeaking != on else { return }
        isSpeaking = on
        onSpeaking?(on)
    }

    /// Plays a short sample in the given voice (Settings' Try button).
    func preview(_ text: String, voice: String, speed: Double, base: URL) throws {
        if !engine.isRunning {
            engine.attach(player)
            engine.attach(pitch)
            engine.connect(player, to: pitch, format: speechFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: speechFormat)
            try engine.start()
            player.play()
        }
        stopSpeaking()
        speak([text], voice: voice, speed: speed, base: base)
    }

    // MARK: Helpers

    static func form(_ fields: [String: String], boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 12)
    }

    static func askForAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceError("Threadbear isn't allowed to use the microphone.") }
        default:
            throw VoiceError("Threadbear isn't allowed to use the microphone. Turn it on in System Settings > Privacy & Security > Microphone.")
        }
    }

    // MARK: Microphones

    struct Microphone: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Every input device, by name.
    static func microphones() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Microphone(id: id, uid: uid, name: name)
        }
    }

    static func microphone(uid: String?) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }
        return microphones().first { $0.uid == uid }?.id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func use(_ device: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var device = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { AppLog.write("voice", "couldn't pick that microphone (\(status)); using the default") }
    }
}

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Double {
    var finite: Double { isFinite ? self : 0 }
}

/// 16-bit PCM out of a WAV that arrives in pieces: skips the header (its
/// chunks, up to "data"), then hands back whole samples, keeping an odd
/// byte for the next piece.
struct WAVStream {
    private var header = Data()
    private var inData = false
    private var carry: UInt8?

    mutating func samples(from piece: Data) -> [Int16] {
        var bytes = piece
        if !inData {
            header.append(bytes)
            guard let start = Self.dataStart(header) else { return [] }
            inData = true
            bytes = header.subdata(in: start..<header.count)
            header = Data()
        }
        var all = [UInt8]()
        all.reserveCapacity(bytes.count + 1)
        if let carry { all.append(carry) }
        all.append(contentsOf: bytes)
        carry = all.count % 2 == 1 ? all.removeLast() : nil
        var out = [Int16](repeating: 0, count: all.count / 2)
        for i in 0..<out.count { out[i] = Int16(bitPattern: UInt16(all[2 * i]) | UInt16(all[2 * i + 1]) << 8) }
        return out
    }

    /// Where the samples start: after "data" and its size.
    static func dataStart(_ header: Data) -> Int? {
        let b = [UInt8](header)
        guard b.count >= 12 else { return nil }
        var i = 12
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i + 4], encoding: .ascii)
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            if id == "data" { return i + 8 }
            i += 8 + size
        }
        return nil
    }
}
