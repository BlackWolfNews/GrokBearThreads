import SwiftUI

/// The bear, drawn as line glyphs like the Mac app's Bear.swift (same 24 by
/// 24 grid, same strokes), so it takes the text colour around it and stays
/// crisp at any size.
struct BearView: View {
    enum Pose { case wave, sleep, sit }

    var pose: Pose
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 24
            context.scaleBy(x: scale, y: scale)
            let shading = GraphicsContext.Shading.foreground
            switch pose {
            case .wave: Self.wave(&context, shading)
            case .sleep: Self.sleep(&context, shading)
            case .sit: Self.sit(&context, shading)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(pose == .sleep ? "The bear, asleep" : pose == .wave ? "The bear, waving" : "The bear")
    }

    private static let line: CGFloat = 1.6

    private static func stroke(_ path: Path, _ context: inout GraphicsContext, _ shading: GraphicsContext.Shading, width: CGFloat = line) {
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private static func head(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading, centre c: CGPoint, radius r: CGFloat,
                             ear: CGFloat, eyesShut: Bool = false, eyes: Bool = true) {
        // Ears clipped to outside the head, so the outlines don't cross.
        var outside = context
        var clip = Path(CGRect(x: -10, y: -10, width: 44, height: 44))
        clip.addPath(circle(c, r))
        outside.clip(to: clip, style: FillStyle(eoFill: true))
        for sign in [-1.0, 1.0] {
            stroke(circle(CGPoint(x: c.x + sign * r * 0.72, y: c.y - r * 0.72), ear), &outside, shading)
        }
        stroke(circle(c, r), &context, shading)
        let eyeY = c.y - r * 0.12
        for sign in eyes ? [-1.0, 1.0] : [] {
            let x = c.x + sign * r * 0.4
            if eyesShut {
                var shut = Path()
                shut.move(to: CGPoint(x: x - r * 0.2, y: eyeY - r * 0.06))
                shut.addCurve(to: CGPoint(x: x + r * 0.2, y: eyeY - r * 0.06),
                              control1: CGPoint(x: x - r * 0.1, y: eyeY + r * 0.16),
                              control2: CGPoint(x: x + r * 0.1, y: eyeY + r * 0.16))
                stroke(shut, &context, shading, width: line * 0.85)
            } else {
                context.fill(circle(CGPoint(x: x, y: eyeY), r * 0.14), with: shading)
            }
        }
        let noseW = r * 0.34, noseH = r * 0.24
        context.fill(Path(ellipseIn: CGRect(x: c.x - noseW / 2, y: c.y + r * 0.3 - noseH / 2, width: noseW, height: noseH)), with: shading)
    }

    private static func wave(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        waveFace(&context, shading)
        waveEyes(&context, shading)
        wavePaw(&context, shading)
    }

    // The waving pose in parts, for WavingBear to move separately.
    fileprivate static let waveHeadCentre = CGPoint(x: 10.5, y: 12.5)
    fileprivate static let waveHeadRadius: CGFloat = 7
    fileprivate static let waveEyeY = waveHeadCentre.y - waveHeadRadius * 0.12
    fileprivate static let shoulder = CGPoint(x: 16.4, y: 16.6)

    fileprivate static func waveFace(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        head(&context, shading, centre: waveHeadCentre, radius: waveHeadRadius, ear: 2.6, eyes: false)
    }

    fileprivate static func waveEyes(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        for sign in [-1.0, 1.0] {
            let x = waveHeadCentre.x + sign * waveHeadRadius * 0.4
            context.fill(circle(CGPoint(x: x, y: waveEyeY), waveHeadRadius * 0.14), with: shading)
        }
    }

    fileprivate static func wavePaw(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        var arm = Path()
        arm.move(to: shoulder)
        arm.addCurve(to: CGPoint(x: 20.4, y: 9.4), control1: CGPoint(x: 19.6, y: 15.6), control2: CGPoint(x: 21.4, y: 12.4))
        stroke(arm, &context, shading)
        let paw = CGPoint(x: 20.6, y: 6.6), pr: CGFloat = 2.4
        stroke(circle(paw, pr), &context, shading)
        for angle in [220.0, 270.0, 320.0] {
            let rad = angle * .pi / 180
            context.fill(circle(CGPoint(x: paw.x + cos(rad) * (pr + 1.5), y: paw.y + sin(rad) * (pr + 1.5)), 0.75), with: shading)
        }
    }

    private static func sleep(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        let c = CGPoint(x: 10.5, y: 13.5)
        var tilted = context
        tilted.translateBy(x: c.x, y: c.y)
        tilted.rotate(by: .degrees(12))
        tilted.translateBy(x: -c.x, y: -c.y)
        head(&tilted, shading, centre: c, radius: 7, ear: 2.6, eyesShut: true)
        z(&context, shading, at: CGPoint(x: 17.2, y: 8.6), size: 2.6)
        z(&context, shading, at: CGPoint(x: 20.4, y: 3.6), size: 3.4)
    }

    private static func z(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading, at o: CGPoint, size: CGFloat) {
        var path = Path()
        path.move(to: o)
        path.addLine(to: CGPoint(x: o.x + size, y: o.y))
        path.addLine(to: CGPoint(x: o.x, y: o.y + size))
        path.addLine(to: CGPoint(x: o.x + size, y: o.y + size))
        stroke(path, &context, shading, width: line * 0.85)
    }

    private static func sit(_ context: inout GraphicsContext, _ shading: GraphicsContext.Shading) {
        let r: CGFloat = 5.6, c = CGPoint(x: 12, y: 8.6)
        let body = CGRect(x: 5.2, y: 12.2, width: 13.6, height: 10.6)
        var outside = context
        var clip = Path(CGRect(x: -10, y: -10, width: 44, height: 44))
        clip.addPath(circle(c, r))
        outside.clip(to: clip, style: FillStyle(eoFill: true))
        stroke(Path(ellipseIn: body), &outside, shading)
        head(&context, shading, centre: c, radius: r, ear: 2.1)
        // The seam down the belly, with three stitches: the threadbear bit.
        let a = CGPoint(x: 12, y: body.minY + 3), b = CGPoint(x: 12, y: body.maxY - 2.2)
        var seam = Path()
        seam.move(to: a)
        seam.addLine(to: b)
        stroke(seam, &context, shading, width: line * 0.8)
        for t in [0.25, 0.5, 0.75] {
            let y = a.y + (b.y - a.y) * t
            var stitch = Path()
            stitch.move(to: CGPoint(x: 11.1, y: y))
            stitch.addLine(to: CGPoint(x: 12.9, y: y))
            stroke(stitch, &context, shading, width: line * 0.7)
        }
    }
}

/// The working line's bear, alive: it pops up, gives a little wave every
/// few seconds, breathes and blinks, with the same timings as the Mac's
/// WavingBearView. The wave comes in bursts rather than flapping non-stop
/// beside the text. Under Reduce Motion it's the still pose.
struct WavingBear: View {
    var size: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        if reduceMotion {
            BearView(pose: .wave, size: size)
        } else {
            let feet = UnitPoint(x: BearView.waveHeadCentre.x / 24, y: (BearView.waveHeadCentre.y + BearView.waveHeadRadius) / 24)
            ZStack {
                part(BearView.waveFace)
                part(BearView.waveEyes)
                    .keyframeAnimator(initialValue: 1.0, repeating: true) { eyes, open in
                        eyes.scaleEffect(y: open, anchor: UnitPoint(x: 0.5, y: BearView.waveEyeY / 24))
                    } keyframes: { _ in
                        // One blink partway through, then a double one.
                        KeyframeTrack {
                            LinearKeyframe(1, duration: 3)
                            LinearKeyframe(0.12, duration: 0.06)
                            LinearKeyframe(1, duration: 0.08)
                            LinearKeyframe(1, duration: 3.56)
                            LinearKeyframe(0.12, duration: 0.06)
                            LinearKeyframe(1, duration: 0.08)
                            LinearKeyframe(0.12, duration: 0.06)
                            LinearKeyframe(1, duration: 0.08)
                            LinearKeyframe(1, duration: 0.32)
                        }
                    }
                part(BearView.wavePaw)
                    .keyframeAnimator(initialValue: 0.0, repeating: true) { paw, angle in
                        paw.rotationEffect(.degrees(angle), anchor: UnitPoint(x: BearView.shoulder.x / 24, y: BearView.shoulder.y / 24))
                    } keyframes: { _ in
                        KeyframeTrack { Self.waveKeyframes(scale: 1) }
                    }
            }
            .frame(width: size, height: size)
            // The whole bear leans with the wave, a fraction as far.
            .keyframeAnimator(initialValue: 0.0, repeating: true) { bear, angle in
                bear.rotationEffect(.degrees(angle), anchor: feet)
            } keyframes: { _ in
                KeyframeTrack { Self.waveKeyframes(scale: -0.16) }
            }
            .keyframeAnimator(initialValue: 1.0, repeating: true) { bear, scale in
                bear.scaleEffect(scale, anchor: feet)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.03, duration: 1.7)
                    CubicKeyframe(1, duration: 1.7)
                }
            }
            .scaleEffect(arrived ? 1 : 0.4, anchor: feet)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { arrived = true }
            }
            .accessibilityElement()
            .accessibilityLabel("The bear, waving")
        }
    }

    /// The paw's swing, six seconds from rest to rest: a burst of waving,
    /// then a pause. Outward only, as at rest it's already against the ear.
    @KeyframeTrackContentBuilder<Double>
    private static func waveKeyframes(scale: Double) -> some KeyframeTrackContent<Double> {
        CubicKeyframe(14 * scale, duration: 0.16)
        CubicKeyframe(3 * scale, duration: 0.22)
        CubicKeyframe(14 * scale, duration: 0.22)
        CubicKeyframe(3 * scale, duration: 0.22)
        CubicKeyframe(10 * scale, duration: 0.22)
        CubicKeyframe(0, duration: 0.26)
        LinearKeyframe(0, duration: 4.7)
    }

    /// One part of the pose on its own canvas, so it can move by itself.
    private func part(_ draw: @escaping (inout GraphicsContext, GraphicsContext.Shading) -> Void) -> some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 24
            context.scaleBy(x: scale, y: scale)
            draw(&context, .foreground)
        }
        .frame(width: size, height: size)
    }
}

/// "Bear with me · 12s" with the waving bear, while a turn runs. The
/// seconds count from when the phone first saw it working.
struct WorkingLine: View {
    var text: String?
    @State private var started = Date.now

    var body: some View {
        HStack(spacing: 8) {
            // Outside the timeline, so the once-a-second redraw of the
            // seconds leaves the bear's movement alone.
            WavingBear(size: 24)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(label(now: context.date))
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func label(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        guard let text, !text.isEmpty, text != "Bear with me" else { return "Bear with me · \(elapsed)" }
        return "\(text) · \(elapsed)"
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack { BearView(pose: .wave, size: 60); BearView(pose: .sleep, size: 60); BearView(pose: .sit, size: 60) }
        WorkingLine(text: "Running npm test")
    }
}
