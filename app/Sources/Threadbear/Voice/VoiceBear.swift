import SwiftUI
import ThreadbearCore

/// Voice mode's avatar: Threadbear's own bear (Bear.swift's face, its
/// head, ears, eyes and nose on the same 24-point grid), drawn big and
/// moving with the conversation. It blinks and its ears perk while it
/// listens, nods along as Mike talks, looks up with thought dots while the
/// agent works, and opens its mouth in time with its own voice.
struct VoiceBear: View {
    enum Mood: Equatable { case waking, listening, hearing, thinking, speaking }

    let mood: Mood
    /// 0...1: his voice while listening, its own while speaking.
    let level: CGFloat

    @State private var smoothed: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(in: &ctx, size: size, t: t)
            }
        }
        .onChange(of: level) { _, new in
            // Quick to open, slower to close, so the mouth doesn't flicker.
            smoothed = new > smoothed ? new : smoothed * 0.6 + new * 0.4
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        switch mood {
        case .waking: "The bear, waking up"
        case .listening: "The bear, listening"
        case .hearing: "The bear, listening to you"
        case .thinking: "The bear, thinking"
        case .speaking: "The bear, talking"
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let scale = min(size.width, size.height) / 24
        ctx.scaleBy(x: scale, y: scale)
        let ink = GraphicsContext.Shading.color(.primary)
        let line: CGFloat = 1.3

        // How the head moves: a nod as he talks, a bob as it talks, a slow
        // sway while it thinks, a tilt of interest while it listens.
        var tilt = 0.0, dy = 0.0
        switch mood {
        case .waking: tilt = -6 * (1 - min(1, (t.truncatingRemainder(dividingBy: 2)) / 2))
        case .listening: tilt = 4 * sin(t * 0.8)
        case .hearing: dy = Double(smoothed) * 0.8 * sin(t * 9); tilt = 6
        case .thinking: tilt = 6 * sin(t * 1.3)
        case .speaking: dy = Double(smoothed) * 0.6 * sin(t * 14)
        }
        let c = CGPoint(x: 12, y: 13.5 + dy)
        let r: CGFloat = 7.6
        var head = ctx
        head.translateBy(x: c.x, y: c.y)
        head.rotate(by: .degrees(tilt))
        head.translateBy(x: -c.x, y: -c.y)

        // Ears, behind the head: perk up while listening.
        let perk: CGFloat = (mood == .listening || mood == .hearing) ? 0.6 + 0.3 * CGFloat(sin(t * 3)) * (mood == .hearing ? 1 : 0.3) : 0
        let earR: CGFloat = 2.8
        for sign in [-1.0, 1.0] {
            let ear = CGPoint(x: c.x + sign * r * 0.72, y: c.y - r * 0.72 - perk)
            let earPath = Path(ellipseIn: CGRect(x: ear.x - earR, y: ear.y - earR, width: 2 * earR, height: 2 * earR))
            head.fill(earPath, with: .color(Color(nsColor: .windowBackgroundColor)))
            head.stroke(earPath, with: ink, lineWidth: line)
            let inner = Path(ellipseIn: CGRect(x: ear.x - earR * 0.45, y: ear.y - earR * 0.45, width: earR * 0.9, height: earR * 0.9))
            head.fill(inner, with: .color(.primary.opacity(0.18)))
        }
        let face = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        head.fill(face, with: .color(Color(nsColor: .windowBackgroundColor)))
        head.stroke(face, with: ink, lineWidth: line)

        // Eyes: blink every few seconds; look up and aside while thinking.
        let blink = Self.blink(t)
        let look: CGPoint = mood == .thinking ? CGPoint(x: 0.9, y: -0.9) : .zero
        let eyeY = c.y - r * 0.12 + look.y
        for sign in [-1.0, 1.0] {
            let x = c.x + sign * r * 0.4 + look.x
            if mood == .waking || blink < 0.15 {
                var shut = Path()
                shut.move(to: CGPoint(x: x - r * 0.18, y: eyeY))
                shut.addQuadCurve(to: CGPoint(x: x + r * 0.18, y: eyeY), control: CGPoint(x: x, y: eyeY + r * 0.14))
                head.stroke(shut, with: ink, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
            } else {
                let dot = r * (mood == .hearing ? 0.16 : 0.14)
                head.fill(Path(ellipseIn: CGRect(x: x - dot, y: eyeY - dot * blink, width: 2 * dot, height: 2 * dot * blink)), with: ink)
                // A glint, so it looks alive.
                let glint = dot * 0.4
                head.fill(Path(ellipseIn: CGRect(x: x + dot * 0.2, y: eyeY - dot * 0.6 * blink, width: glint, height: glint * blink)), with: .color(Color(nsColor: .windowBackgroundColor)))
            }
        }

        // Muzzle and nose.
        let muzzle = CGRect(x: c.x - r * 0.42, y: c.y + r * 0.12, width: r * 0.84, height: r * 0.62)
        head.fill(Path(ellipseIn: muzzle), with: .color(.primary.opacity(0.08)))
        let noseW = r * 0.34, noseH = r * 0.24
        let noseY = c.y + r * 0.3
        head.fill(Path(ellipseIn: CGRect(x: c.x - noseW / 2, y: noseY - noseH / 2, width: noseW, height: noseH)), with: ink)

        // Mouth: opens with its voice; a small smile otherwise.
        let mouthY = noseY + noseH / 2 + r * 0.12
        if mood == .speaking {
            let open = max(0.08, min(1, smoothed)) * r * 0.34
            let mouth = Path(roundedRect: CGRect(x: c.x - r * 0.16, y: mouthY, width: r * 0.32, height: open), cornerRadius: r * 0.16)
            head.fill(mouth, with: ink)
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: c.x - r * 0.2, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: c.x + r * 0.2, y: mouthY), control: CGPoint(x: c.x, y: mouthY + r * 0.2))
            head.stroke(smile, with: ink, style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
        }

        // The stitches: a seam across the top of the head.
        var seam = Path()
        seam.move(to: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.72))
        seam.addLine(to: CGPoint(x: c.x + r * 0.3, y: c.y - r * 0.66))
        head.stroke(seam, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: line * 0.6, lineCap: .round))

        // Thought dots while it works, rising one after another.
        if mood == .thinking {
            for i in 0..<3 {
                let phase = (t * 1.5 - Double(i) * 0.35).truncatingRemainder(dividingBy: 1.5) / 1.5
                let alpha = max(0, sin(phase * .pi))
                let d = 0.6 + Double(i) * 0.35
                let p = CGPoint(x: 19.2 + Double(i) * 1.3, y: 6.2 - Double(i) * 1.4)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(.primary.opacity(alpha * 0.7)))
            }
        }
    }

    /// 1 with eyes open, dipping to 0 for a quick blink about every four seconds.
    static func blink(_ t: Double) -> CGFloat {
        let period = 4.2
        let x = t.truncatingRemainder(dividingBy: period)
        guard x > period - 0.16 else { return 1 }
        let p = (x - (period - 0.16)) / 0.16
        return CGFloat(abs(cos(p * .pi)))
    }
}

/// The stage above the message box while Voice is on: the bear, and in a
/// bubble beside it what he's saying or what it's doing.
struct VoiceStage: View {
    let threadId: String
    @State private var voice = VoiceMode.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(captionIsHim ? .primary : .secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: 360, alignment: .trailing)
                    .tip(caption)
            }
            VoiceBear(mood: mood, level: CGFloat(voice.level))
                .frame(width: 64, height: 64)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var mood: VoiceBear.Mood {
        switch voice.phase {
        case .starting: .waking
        case .listening, .off, .failed: .listening
        case .hearing: .hearing
        case .thinking: .thinking
        case .speaking: .speaking
        }
    }

    private var captionIsHim: Bool {
        if case .hearing = voice.phase { return true }
        return false
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
