import SwiftUI
import ThreadbearCore

/// Voice mode's button beside Send: a waveform in a circle, blue to start
/// and red while it's on, its bars moving with whoever is talking. The
/// words he's saying, or what it's doing, show beside it.
struct VoiceButton: View {
    let threadId: String
    let size: CGFloat
    @State private var voice = VoiceMode.shared

    var body: some View {
        let on = voice.isOn(for: threadId)
        HStack(spacing: 6) {
            if on, let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .transition(.opacity)
                    .tip(caption)
            }
            Button {
                voice.toggle(threadId: threadId)
            } label: {
                VoiceBars(level: on ? CGFloat(voice.level) : 0, active: on, busy: busy)
                    .frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(on ? Color.red : Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tip(on ? "End voice" : "Talk with this thread out loud")
            .accessibilityLabel(on ? "End voice" : "Start voice")
        }
        .animation(.easeOut(duration: 0.15), value: on)
        .popover(isPresented: failureShown) {
            if case .failed(let message) = voice.phase {
                Text(message)
                    .padding(12)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: {
            if case .failed = voice.phase, voice.threadId == threadId { return true }
            return false
        }, set: { if !$0 { voice.dismissFailure() } })
    }

    private var busy: Bool {
        switch voice.phase {
        case .starting, .thinking: true
        default: false
        }
    }

    private var caption: String? {
        switch voice.phase {
        case .starting(let status): status
        case .listening: "Listening…"
        case .hearing(let words): words.isEmpty ? "Listening…" : words
        case .thinking: "Working on it…"
        case .speaking: "Speaking"
        case .off, .failed: nil
        }
    }
}

/// Five bars: still when off, gently pulsing while busy, and following the
/// sound level while someone talks.
struct VoiceBars: View {
    let level: CGFloat
    let active: Bool
    let busy: Bool
    private let shape: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: geo.size.width * 0.1) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .frame(width: geo.size.width * 0.12, height: geo.size.height * height(i, t))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        guard active else { return shape[i] * 0.8 }
        if busy, level < 0.05 { return 0.3 + 0.25 * CGFloat((sin(t * 4 + Double(i) * 0.8) + 1) / 2) }
        let wobble = CGFloat((sin(t * 11 + Double(i) * 1.7) + 1) / 2)
        return max(0.2, min(1, shape[i] * (0.25 + level * (0.6 + 0.4 * wobble))))
    }
}
