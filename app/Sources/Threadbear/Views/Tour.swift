import AppKit
import SwiftUI

/// The parts of the window the tour points at. Each is tagged where it's
/// drawn (`tourTarget`), so the tour finds it wherever Mike's dock has put
/// it, and skips it when it isn't on screen at all.
enum TourTarget: Hashable {
    case activityBar
    case threads
    case composer
    /// The composer's Full access / Ask before edits chip.
    case permission
    /// The Highlights panel, or its icon on the rail when the panel's
    /// closed.
    case highlights
    case highlightsRail
    case usage
    /// The gear at the foot of the activity bar.
    case settings
}

/// Which side of what it points at the tour's card goes, in the order
/// they're tried.
enum TourEdge {
    case right, left, below, above
}

struct TourStep: Equatable {
    /// Nil for the welcome and the last step, which sit in the middle of
    /// the window with nothing lit up.
    var targets: [TourTarget] = []
    let title: String
    let body: String
    var edges: [TourEdge] = [.right, .left, .below, .above]
    /// The bear on the card.
    var bear: Bear.Pose? = nil
}

/// A short look round the window for someone new: the window dims and
/// each step lights up one part of it with a card beside it. It starts by
/// itself the first time the app connects to its runner, and Help > Take
/// the Tour runs it again. It only points: it never starts a thread or
/// opens a folder, so a new install's first thread goes where they choose.
@MainActor
@Observable
final class Tour {
    static let shared = Tour()
    static let seenKey = "tourSeen"

    static let steps: [TourStep] = [
        TourStep(title: "Welcome to Threadbear", body: "A quick look round before you start. It takes about a minute.", bear: .wave),
        TourStep(targets: [.activityBar], title: "Your views",
                 body: "Switch between your threads, the ones you've put to sleep, the archive, schedules and projects. ⌘1 to ⌘6 get you there too."),
        TourStep(targets: [.threads], title: "Threads",
                 body: "Everything your agents are working on. A thread that needs you moves to the top and gets a dot."),
        TourStep(targets: [.composer], title: "Start a thread",
                 body: "Say what you want done and press Return. The folder, account and model are on the composer if you want to change them.",
                 edges: [.above, .below, .right, .left]),
        // The one choice that matters for safety, so it gets a step of its own.
        TourStep(targets: [.permission], title: "Full access or ask first",
                 body: "With Full access the agent edits files and runs commands on its own. Ask before edits stops for your OK each time. You choose per thread.",
                 edges: [.above, .below, .right, .left]),
        TourStep(targets: [.highlights, .highlightsRail], title: "Highlights",
                 body: "Files, links and questions the agent pins for you, so you don't have to dig through the thread for them."),
        TourStep(targets: [.usage], title: "Usage",
                 body: "How much room each of your logins has left before it hits its limit."),
        // Pairing and signing in live in Settings, where a new user
        // wouldn't think to look for them.
        TourStep(targets: [.settings], title: "Your phone and a browser",
                 body: "Settings › Phone & browser pairs the iPhone app and signs a browser in to your threads' website."),
        TourStep(title: "That's the lot",
                 body: "Drag any panel by its bar to move it where you like. You can take this tour again from the Help menu.", bear: .sit),
    ]

    /// The step on show, as an index into `shown`; nil when the tour's
    /// not running.
    private(set) var step: Int?
    /// The steps this run shows: the ones whose part of the window was on
    /// screen when it started.
    private(set) var shown: [TourStep] = []
    /// Where each tagged part of the window is, in the window's content
    /// (RootView's `Tour.space`).
    var frames: [TourTarget: CGRect] = [:]
    @ObservationIgnored var defaults: UserDefaults = .standard

    static let space = "tour"

    var current: TourStep? { step.map { shown[$0] } }
    var isLast: Bool { step == shown.count - 1 }

    /// Where the step's part of the window is, or nil to put the card in
    /// the middle.
    func frame(for step: TourStep) -> CGRect? {
        step.targets.lazy.compactMap { self.frames[$0] }.first { $0.width > 1 && $0.height > 1 }
    }

    /// The first time the app has connected on this Mac.
    func startIfNew() {
        guard !defaults.bool(forKey: Self.seenKey), step == nil else { return }
        start()
    }

    func start() {
        shown = Self.steps.filter { $0.targets.isEmpty || frame(for: $0) != nil }
        step = 0
        // The composer has the keyboard on a new thread: Return and Esc are
        // the tour's while it's up, not a send or an empty line.
        NSApp?.mainWindow?.makeFirstResponder(nil)
    }

    func next() {
        guard let step else { return }
        if step + 1 < shown.count { self.step = step + 1 } else { finish() }
    }

    func back() {
        guard let step, step > 0 else { return }
        self.step = step - 1
    }

    /// Done or skipped: either way it doesn't come up by itself again.
    func finish() {
        step = nil
        defaults.set(true, forKey: Self.seenKey)
    }

    /// Where the card goes: beside `target` on the first of `edges` with
    /// room for it, else in the middle of `bounds`. Kept `margin` in from
    /// the window's edges.
    nonisolated static func cardOrigin(target: CGRect?, card: CGSize, bounds: CGRect, edges: [TourEdge],
                                       gap: CGFloat = 14, margin: CGFloat = 12) -> CGPoint {
        let centred = CGPoint(x: bounds.midX - card.width / 2, y: bounds.midY - card.height / 2)
        guard let target else { return centred }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX + margin), bounds.maxX - margin - card.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, bounds.minY + margin), bounds.maxY - margin - card.height) }
        for edge in edges {
            switch edge {
            case .right where target.maxX + gap + card.width <= bounds.maxX - margin:
                return CGPoint(x: target.maxX + gap, y: clampY(target.midY - card.height / 2))
            case .left where target.minX - gap - card.width >= bounds.minX + margin:
                return CGPoint(x: target.minX - gap - card.width, y: clampY(target.midY - card.height / 2))
            case .below where target.maxY + gap + card.height <= bounds.maxY - margin:
                return CGPoint(x: clampX(target.midX - card.width / 2), y: target.maxY + gap)
            case .above where target.minY - gap - card.height >= bounds.minY + margin:
                return CGPoint(x: clampX(target.midX - card.width / 2), y: target.minY - gap - card.height)
            default:
                continue
            }
        }
        return centred
    }
}

extension View {
    /// Marks this view as the part of the window a tour step points at.
    /// `withBar` for a dock panel's content: the spotlight takes in the
    /// panel's bar above it too, so it reads as the whole panel.
    func tourTarget(_ target: TourTarget, withBar: Bool = false) -> some View {
        modifier(TourTargetModifier(target: target, bar: withBar ? RootView.options.headerHeight : 0))
    }
}

private struct TourTargetModifier: ViewModifier {
    let target: TourTarget
    let bar: CGFloat

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Tour.space)) } action: { frame in
                Tour.shared.frames[target] = CGRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: frame.height + bar)
            }
            // A closed panel's frame would leave the tour lighting up
            // whatever took its place.
            .onDisappear { Tour.shared.frames[target] = nil }
    }
}

/// The dimmed window with the step's part cut out of it, and the card.
/// Over RootView, in its `Tour.space`.
struct TourOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var cardSize = CGSize(width: 300, height: 160)

    var body: some View {
        let tour = Tour.shared
        if let index = tour.step, let step = tour.current {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let target = tour.frame(for: step)
                // A few points round it, and never past the window's edge.
                let hole = target.map { $0.insetBy(dx: -4, dy: -4).intersection(bounds) }
                let origin = Tour.cardOrigin(target: hole, card: cardSize, bounds: bounds, edges: step.edges)
                ZStack(alignment: .topLeading) {
                    Spotlight(hole: hole ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
                        // Darker in dark mode, where 0.4 barely showed
                        // against the dark panels.
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.35), style: FillStyle(eoFill: true))
                        // Clicks on the window behind wait until the tour's
                        // done or skipped.
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    if let hole {
                        RoundedRectangle(cornerRadius: Spotlight.corner)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                            .frame(width: hole.width, height: hole.height)
                            .offset(x: hole.minX, y: hole.minY)
                            .allowsHitTesting(false)
                    }
                    TourCard(step: step, index: index, count: tour.shown.count)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                }
                .animation(Juice.reduceMotion ? nil : .snappy(duration: 0.3), value: index)
            }
            .transition(.opacity)
        }
    }
}

/// The window with a rounded hole in it, filled even-odd. The hole moves
/// from one part to the next rather than jumping.
private struct Spotlight: Shape {
    static let corner: CGFloat = 10
    var hole: CGRect

    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: Self.corner, height: Self.corner))
        return path
    }
}

private struct TourCard: View {
    let step: TourStep
    let index: Int
    let count: Int

    var body: some View {
        let tour = Tour.shared
        VStack(alignment: .leading, spacing: zoomed(8)) {
            if let bear = step.bear {
                Image(nsImage: Bear.image(bear, side: zoomed(44)))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(step.title)
                .font(.system(size: TypeScale.cardTitle + 1, weight: .semibold))
            Text(step.body)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: zoomed(8)) {
                // Where you are in it, as dots: the step on show is darker.
                HStack(spacing: zoomed(5)) {
                    ForEach(0..<count, id: \.self) { dot in
                        Circle()
                            .fill(dot == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                            .frame(width: zoomed(5), height: zoomed(5))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(index + 1) of \(count)")
                Spacer(minLength: zoomed(8))
                if !tour.isLast {
                    Button("Skip") { withAnimation(.easeOut(duration: 0.2)) { tour.finish() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                        .tip("End the tour (Esc). Help > Take the Tour brings it back")
                }
                if index > 0 {
                    Button("Back") { tour.back() }
                        .tip("The step before")
                }
                Button(tour.isLast ? "Done" : index == 0 ? "Show me" : "Next") {
                    if tour.isLast {
                        withAnimation(.easeOut(duration: 0.2)) { tour.finish() }
                    } else {
                        tour.next()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tip(tour.isLast ? "Close the tour (Return)" : "The next step (Return)")
            }
            .font(.system(size: TypeScale.label))
            .padding(.top, zoomed(4))
        }
        .padding(zoomed(16))
        .frame(width: zoomed(300), alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}
