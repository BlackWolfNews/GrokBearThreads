import SwiftUI
import ThreadbearCore

/// Voice mode's avatar: Threadbear's mascot as in its sprites
/// (docs/threadbear-design/sprites): tan fur, cream ears and muzzle, a
/// patch with a button eye, a stitched seam, drawn in code so it can move
/// with the conversation. It blinks and its ears perk while it
/// listens, nods along as Mike talks, looks up with thought dots while the
/// agent works, and opens its mouth in time with its own voice.
struct VoiceBear: View {
    enum Mood: Equatable { case waking, listening, hearing, thinking, speaking }

    let mood: Mood
    /// 0...1: his voice while listening, its own while speaking.
    let level: CGFloat

    @State private var smoothed: CGFloat = 0
    /// How open the mouth is, how much it nods: the smoothed level, or the
    /// level itself before it has changed.
    private var amount: CGFloat { max(smoothed, level * 0.8) }

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

    // The mascot's colours (docs/threadbear-design/sprites).
    static let fur = Color(red: 0.84, green: 0.58, blue: 0.33)
    static let furEdge = Color(red: 0.66, green: 0.42, blue: 0.21)
    static let cream = Color(red: 0.96, green: 0.84, blue: 0.67)
    static let patch = Color(red: 0.45, green: 0.31, blue: 0.21)
    static let button = Color(red: 0.42, green: 0.27, blue: 0.18)
    static let buttonRim = Color(red: 0.30, green: 0.19, blue: 0.12)
    static let thread = Color(red: 0.55, green: 0.36, blue: 0.19)
    static let dark = Color(red: 0.20, green: 0.12, blue: 0.08)

    private func draw(in ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let scale = min(size.width, size.height) / 24
        ctx.scaleBy(x: scale, y: scale)

        // How the head moves: a nod as he talks, a bob as it talks, a slow
        // sway while it thinks, a tilt of interest while it listens.
        var tilt = 0.0, dy = 0.0
        switch mood {
        case .waking: tilt = -6 * (1 - min(1, t.truncatingRemainder(dividingBy: 2) / 2))
        case .listening: tilt = 4 * sin(t * 0.8)
        case .hearing: dy = Double(amount) * 0.8 * sin(t * 9); tilt = 6
        case .thinking: tilt = 6 * sin(t * 1.3)
        case .speaking: dy = Double(amount) * 0.6 * sin(t * 14)
        }
        let c = CGPoint(x: 11.4, y: 13.6 + dy)
        let rx: CGFloat = 8.3, ry: CGFloat = 7.5
        var head = ctx
        head.translateBy(x: c.x, y: c.y)
        head.rotate(by: .degrees(tilt))
        head.translateBy(x: -c.x, y: -c.y)
        let edge: CGFloat = 0.45

        // Ears, behind the head: round, cream inside, perking up to listen.
        let perk: CGFloat = (mood == .listening || mood == .hearing) ? 0.5 + 0.3 * CGFloat(sin(t * 3)) * (mood == .hearing ? 1 : 0.3) : 0
        for sign in [-1.0, 1.0] {
            let e = CGPoint(x: c.x + sign * rx * 0.78, y: c.y - ry * 0.78 - perk)
            let r: CGFloat = 3.0
            let ear = Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r))
            head.fill(ear, with: .color(Self.fur))
            head.stroke(ear, with: .color(Self.furEdge), lineWidth: edge)
            let ir: CGFloat = 1.7
            head.fill(Path(ellipseIn: CGRect(x: e.x - ir + sign * 0.2, y: e.y - ir + 0.3, width: 2 * ir, height: 2 * ir)), with: .color(Self.cream))
        }

        // The head, a little wider than tall.
        let face = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        head.fill(face, with: .color(Self.fur))
        head.stroke(face, with: .color(Self.furEdge), lineWidth: edge)

        // The patch over his right eye (our left), stitched round its edge.
        var patch = Path()
        patch.move(to: CGPoint(x: c.x - rx * 0.95, y: c.y - ry * 0.55))
        patch.addLine(to: CGPoint(x: c.x - rx * 0.32, y: c.y - ry * 0.78))
        patch.addLine(to: CGPoint(x: c.x - rx * 0.12, y: c.y - ry * 0.12))
        patch.addLine(to: CGPoint(x: c.x - rx * 0.70, y: c.y + ry * 0.12))
        patch.closeSubpath()
        var clipped = head
        clipped.clip(to: face)
        clipped.fill(patch, with: .color(Self.patch))
        clipped.stroke(patch, with: .color(Self.cream.opacity(0.8)), style: StrokeStyle(lineWidth: 0.28, lineCap: .round, dash: [0.55, 0.45]))

        // The seam down the forehead, with cross-stitches.
        var seam = Path()
        seam.move(to: CGPoint(x: c.x + 0.4, y: c.y - ry))
        seam.addQuadCurve(to: CGPoint(x: c.x + 0.2, y: c.y - ry * 0.18), control: CGPoint(x: c.x + 0.9, y: c.y - ry * 0.6))
        head.stroke(seam, with: .color(Self.thread), style: StrokeStyle(lineWidth: 0.3, lineCap: .round))
        for f in [0.25, 0.55, 0.82] as [CGFloat] {
            let y = c.y - ry + (ry * 0.82) * f
            let x = c.x + 0.4 + 0.35 * sin(f * .pi)
            var cross = Path()
            cross.move(to: CGPoint(x: x - 0.45, y: y - 0.35)); cross.addLine(to: CGPoint(x: x + 0.45, y: y + 0.35))
            cross.move(to: CGPoint(x: x + 0.45, y: y - 0.35)); cross.addLine(to: CGPoint(x: x - 0.45, y: y + 0.35))
            head.stroke(cross, with: .color(Self.thread), style: StrokeStyle(lineWidth: 0.28, lineCap: .round))
        }

        // The button eye, on the patch: four holes and a cross of thread.
        let look: CGPoint = mood == .thinking ? CGPoint(x: 0.6, y: -0.7) : .zero
        let eyeY = c.y - ry * 0.12
        let bc = CGPoint(x: c.x - rx * 0.42, y: eyeY + 0.45)
        let br: CGFloat = 2.15
        head.fill(Path(ellipseIn: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br)), with: .color(Self.button))
        head.stroke(Path(ellipseIn: CGRect(x: bc.x - br * 0.78, y: bc.y - br * 0.78, width: br * 1.56, height: br * 1.56)), with: .color(Self.buttonRim), lineWidth: 0.25)
        for (dx, dy) in [(-0.55, -0.55), (0.55, -0.55), (-0.55, 0.55), (0.55, 0.55)] as [(CGFloat, CGFloat)] {
            head.fill(Path(ellipseIn: CGRect(x: bc.x + dx - 0.2, y: bc.y + dy - 0.2, width: 0.4, height: 0.4)), with: .color(Self.dark))
        }
        var x = Path()
        x.move(to: CGPoint(x: bc.x - 0.55, y: bc.y - 0.55)); x.addLine(to: CGPoint(x: bc.x + 0.55, y: bc.y + 0.55))
        x.move(to: CGPoint(x: bc.x + 0.55, y: bc.y - 0.55)); x.addLine(to: CGPoint(x: bc.x - 0.55, y: bc.y + 0.55))
        head.stroke(x, with: .color(Self.cream), style: StrokeStyle(lineWidth: 0.22, lineCap: .round))

        // The real eye: shiny, blinking every few seconds, looking up and
        // aside while it thinks, wider while he talks.
        let blink = Self.blink(t)
        let ec = CGPoint(x: c.x + rx * 0.45 + look.x, y: eyeY + look.y)
        if mood == .waking || blink < 0.15 {
            var shut = Path()
            shut.move(to: CGPoint(x: ec.x - 0.9, y: ec.y))
            shut.addQuadCurve(to: CGPoint(x: ec.x + 0.9, y: ec.y), control: CGPoint(x: ec.x, y: ec.y + 0.8))
            head.stroke(shut, with: .color(Self.dark), style: StrokeStyle(lineWidth: 0.45, lineCap: .round))
        } else {
            let ew: CGFloat = mood == .hearing ? 1.05 : 0.95, eh: CGFloat = (mood == .hearing ? 1.35 : 1.25) * blink
            head.fill(Path(ellipseIn: CGRect(x: ec.x - ew, y: ec.y - eh, width: 2 * ew, height: 2 * eh)), with: .color(Self.dark))
            head.fill(Path(ellipseIn: CGRect(x: ec.x - 0.05, y: ec.y - eh * 0.7, width: 0.6, height: 0.6 * blink)), with: .color(.white))
        }

        // Muzzle, nose and mouth.
        let mc = CGPoint(x: c.x + 0.2, y: c.y + ry * 0.42)
        head.fill(Path(ellipseIn: CGRect(x: mc.x - 2.9, y: mc.y - 2.1, width: 5.8, height: 4.2)), with: .color(Self.cream))
        let nose = CGPoint(x: mc.x, y: mc.y - 0.9)
        var n = Path()
        n.move(to: CGPoint(x: nose.x - 0.95, y: nose.y - 0.4))
        n.addQuadCurve(to: CGPoint(x: nose.x + 0.95, y: nose.y - 0.4), control: CGPoint(x: nose.x, y: nose.y - 0.9))
        n.addQuadCurve(to: CGPoint(x: nose.x - 0.95, y: nose.y - 0.4), control: CGPoint(x: nose.x, y: nose.y + 1.0))
        head.fill(n, with: .color(Self.dark))
        let mouthY = nose.y + 0.45
        if mood == .speaking {
            let open = max(0.25, min(1, amount)) * 2.3
            let mouth = Path(roundedRect: CGRect(x: mc.x - 0.95, y: mouthY + 0.1, width: 1.9, height: open), cornerRadius: 0.9)
            head.fill(mouth, with: .color(Self.dark))
            head.fill(Path(ellipseIn: CGRect(x: mc.x - 0.6, y: mouthY + 0.1 + open * 0.5, width: 1.2, height: open * 0.5)), with: .color(Color(red: 0.85, green: 0.45, blue: 0.45)))
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: mc.x, y: mouthY - 0.1))
            smile.addLine(to: CGPoint(x: mc.x, y: mouthY + 0.35))
            smile.move(to: CGPoint(x: mc.x - 1.1, y: mouthY + 0.1))
            smile.addQuadCurve(to: CGPoint(x: mc.x, y: mouthY + 0.35), control: CGPoint(x: mc.x - 0.6, y: mouthY + 0.9))
            smile.addQuadCurve(to: CGPoint(x: mc.x + 1.1, y: mouthY + 0.1), control: CGPoint(x: mc.x + 0.6, y: mouthY + 0.9))
            head.stroke(smile, with: .color(Self.dark), style: StrokeStyle(lineWidth: 0.35, lineCap: .round))
        }

        // Thought dots while it works, rising one after another.
        if mood == .thinking {
            for i in 0..<3 {
                let phase = (t * 1.5 - Double(i) * 0.35).truncatingRemainder(dividingBy: 1.5) / 1.5
                let alpha = max(0, sin(phase * .pi))
                let d = 0.6 + Double(i) * 0.35
                let p = CGPoint(x: 19.6 + Double(i) * 1.2, y: 5.6 - Double(i) * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(Self.cream.opacity(alpha)))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(Self.furEdge.opacity(alpha)), lineWidth: 0.25)
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
                .frame(width: 84, height: 84)
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
