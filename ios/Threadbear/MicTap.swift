import AVFoundation

/// The only place the app puts a tap on the mic. Just after the audio
/// session's category changes (Ask's playAndRecord, a call) the input node
/// can still report the old format, and a tap in a format the hardware isn't
/// running at throws an Objective-C exception, which Swift can't catch. It
/// crashed Ask on 29 Oct and the old reply dictation on 30 Oct, on the XS
/// Max. So this refuses until the format has settled, and
/// callers try again a moment later (it settles within tens of
/// milliseconds). MicTapTests fails on an `installTap(` anywhere else.
nonisolated enum MicTap {
    enum Refusal: Error, Equatable {
        /// No input at all (a simulator without a mic, or one in use).
        case noMicrophone
        /// The node's format isn't the hardware's yet: try again shortly.
        case formatChanging
    }

    /// Puts `block` on bus 0 in the format the mic is running at.
    static func install(on input: AVAudioInputNode, bufferSize: AVAudioFrameCount = 1024,
                        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws(Refusal) {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw .noMicrophone }
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.sampleRate == format.sampleRate else { throw .formatChanging }
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }
}
