import AppKit

/// A short, quiet whoosh as a swiped row leaves (Mike asked 29 Oct).
/// Made here rather than shipped as a file, like the bear: noise through a
/// band-pass filter whose centre sweeps from high to low, the sound of
/// something passing by, under a soft swell and fade. The noise is seeded,
/// so it's the same whoosh every time.
@MainActor
enum Whoosh {
    private static let sound: NSSound? = NSSound(data: wav(samples: render()))

    static func play() {
        // Off with System Settings > Sound > "Play user interface sound
        // effects", as Mail's swoosh is.
        let ui = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
        guard ui, let sound else { return }
        sound.stop()
        sound.volume = 0.35
        sound.play()
    }

    static let rate = 44_100.0

    /// Mono samples in -1...1.
    static func render(duration: Double = 0.26) -> [Double] {
        let count = Int(duration * rate)
        var seed: UInt32 = 0x7EA5
        // A state-variable filter, so its centre can move every sample.
        var low = 0.0, band = 0.0
        let q = 0.9
        var out = [Double](repeating: 0, count: count)
        var peak = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(count)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            // 2.6 kHz down to 450 Hz, falling fastest at the start.
            let centre = 450 + 2150 * pow(1 - t, 2)
            let f = 2 * sin(.pi * centre / rate)
            low += f * band
            let high = noise - low - q * band
            band += f * high
            // Swells in over the first fifth, then fades away smoothly.
            let envelope = t < 0.2 ? sin(t / 0.2 * .pi / 2) : pow(cos((t - 0.2) / 0.8 * .pi / 2), 2)
            out[i] = band * envelope
            peak = max(peak, abs(out[i]))
        }
        return peak > 0 ? out.map { $0 / peak * 0.8 } : out
    }

    /// 16-bit mono PCM in a WAV container, which NSSound reads from memory.
    static func wav(samples: [Double]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate) * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Double(Int16.max))) }
        return data
    }
}
