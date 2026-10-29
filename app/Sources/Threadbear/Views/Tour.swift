import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

/// The parts of the window the tour points at. Each is tagged where it's
/// drawn (`tourTarget`), so the tour finds it wherever Mike's dock has put
/// it, and skips it when it isn't on screen at all.
enum TourTarget: Hashable {
    case threads
    case composer
    /// The composer's Full access / Ask before edits chip.
    case permission
    /// The chips above the composer, from the thread's patches.
    case actionChips
    /// The Highlights panel, or its icon on the rail when the panel's
    /// closed.
    case highlights
    case highlightsRail
    /// The main panel, bar and all: something to drag when Highlights
    /// isn't open.
    case mainPanel
}

/// Which side of what it points at the tour's card goes, in the order
/// they're tried.
enum TourEdge {
    case right, left, below, above
}

/// Something the tour has them do rather than read about (Mike, 29 Oct:
/// show what makes Threadbear interesting, hands-on).
enum TourTask: Equatable {
    /// Drag a panel somewhere else; done when the dock's layout changes.
    case movePanel
    /// Press the Welcome thread's example chip; done once it has run.
    case runPatch
    /// Send the first thread, its message written for them; sending it
    /// ends the tour.
    case sendFirst
}

struct TourStep: Equatable {
    /// Empty for the welcome, which sits in the middle of the window with
    /// nothing lit up.
    var targets: [TourTarget] = []
    let title: String
    let body: String
    var task: TourTask? = nil
    /// What the card says once the task's done.
    var doneBody: String? = nil
    var edges: [TourEdge] = [.right, .left, .below, .above]
    /// The bear on the card.
    var bear: Bear.Pose? = nil
}

/// A short, hands-on look round the window for someone new: the window
/// dims and each step lights up one part of it with a card beside it, and
/// three of them have you do the thing (move a panel, press a patch's chip,
/// send your first thread). It starts by itself the first time the app
/// connects to its runner, with no Skip then, and Help > Take the Tour runs
/// it again, skippable. The only thread it makes is the Welcome thread in
/// ~/Threadbear/Welcome, with no turn, for its example chip; the first real
/// thread is theirs to send.
///
/// Copy: notifications are played down and never the reason to pair the
/// phone; the phone is for asking and steering while you're out (Mike,
/// 29 Oct).
@MainActor
@Observable
final class Tour {
    static let shared = Tour()
    static let seenKey = "tourSeen"
    /// The tour's last step writes this in the new-thread composer.
    static let firstMessage = "Make me a patch for this folder that adds a button saying hello, then tell me what you did."
    /// Next turns up on a hands-on step after this long, in case the drag
    /// or the click won't take.
    static let patience: Duration = .seconds(20)

    static let steps: [TourStep] = [
        TourStep(title: "Welcome to Threadbear", body: "A quick, hands-on look round. It takes about a minute.", bear: .wave),
        TourStep(targets: [.threads], title: "Threads",
                 body: "Everything your agents are working on. One that needs you moves to the top. The icons on the left switch to hibernating threads, the archive, schedules and projects."),
        // The one choice that matters for safety, so it gets a step of its own.
        TourStep(targets: [.permission], title: "Full access or ask first",
                 body: "With Full access the agent edits files and runs commands on its own. Ask before edits stops for your OK each time. You choose per thread.",
                 edges: [.above, .below, .right, .left]),
        TourStep(targets: [.highlights, .highlightsRail], title: "Highlights",
                 body: "Files, links and questions the agent pins for you, so you don't have to dig through the thread for them."),
        TourStep(targets: [.highlights, .mainPanel], title: "Move a panel",
                 body: "Every panel can go wherever you like. Drag this one by its bar to another side of the window, or onto another panel to make tabs.",
                 task: .movePanel,
                 doneBody: "That's it. View › Reset Panel Layout puts everything back."),
        TourStep(targets: [.actionChips], title: "Patches",
                 body: "A patch adds buttons, panels and checks to the threads in a folder. This Welcome thread's folder has one. Press Roll a die.",
                 task: .runPatch,
                 doneBody: "That ran a command in the folder. You don't write patches yourself: ask a thread to \"add a button that runs the tests\" and it makes one.",
                 edges: [.above, .right, .left, .below]),
        TourStep(targets: [.composer], title: "Your first thread",
                 body: "We've written its first message for you: it asks for a patch with a hello button of your own. Press Return to send it, and while it works, Finish setting up has the rest.",
                 task: .sendFirst,
                 edges: [.above, .below, .right, .left]),
    ]

    /// The step on show, as an index into `shown`; nil when the tour's
    /// not running.
    private(set) var step: Int?
    /// The steps this run shows: the ones whose part of the window was on
    /// screen when it started, and the hands-on ones, which bring their
    /// part up themselves.
    private(set) var shown: [TourStep] = []
    /// False the first time, when it started by itself: no Skip then
    /// (Mike, 29 Oct). Help's replay can be skipped.
    private(set) var skippable = true
    /// The step's task is done.
    private(set) var taskDone = false
    /// Where each tagged part of the window is, in the window's content
    /// (RootView's `Tour.space`).
    var frames: [TourTarget: CGRect] = [:]
    @ObservationIgnored var framesFrom: [TourTarget: UUID] = [:]
    /// The Welcome thread, once the patch step has opened it.
    private(set) var welcomeThreadId: String?
    @ObservationIgnored var defaults: UserDefaults = .standard
    /// Set by the overlay. Tests leave it nil, so stepping through touches
    /// nothing.
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var layoutAtStart: DockLayout?
    @ObservationIgnored private var sawChipRun = false
    @ObservationIgnored private var threadsAtStart: Set<String> = []

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
        start(skippable: false)
    }

    func start(skippable: Bool = true) {
        self.skippable = skippable
        shown = Self.steps.filter { $0.task != nil || $0.targets.isEmpty || frame(for: $0) != nil }
        go(to: 0)
        // The composer has the keyboard on a new thread: Return is the
        // tour's while it's up, not a send or an empty line.
        NSApp?.mainWindow?.makeFirstResponder(nil)
    }

    func next() {
        guard let step else { return }
        if step + 1 < shown.count { go(to: step + 1) } else { finish() }
    }

    func back() {
        guard let step, step > 0 else { return }
        go(to: step - 1)
    }

    /// Done or skipped: either way it doesn't come up by itself again.
    func finish() {
        step = nil
        defaults.set(true, forKey: Self.seenKey)
    }

    private func go(to index: Int) {
        step = index
        taskDone = false
        guard let app, let task = shown[index].task else { return }
        switch task {
        case .movePanel:
            layoutAtStart = app.dock.layout
        case .runPatch:
            sawChipRun = false
            Task {
                welcomeThreadId = await app.openTourWelcome()
            }
        case .sendFirst:
            threadsAtStart = Set(app.threads.keys)
            app.newThread()
            app.drafts["new"] = Draft(text: Self.firstMessage)
            app.focusRequests["new", default: 0] += 1
        }
    }

    /// Whether the step's task has been done, as the window changes
    /// (TourOverlay calls it).
    func check() {
        guard let app, let task = current?.task, !taskDone else { return }
        switch task {
        case .movePanel:
            if let layoutAtStart, app.dock.layout != layoutAtStart { taskDone = true }
        case .runPatch:
            // Running, then not: the command has finished and its output is
            // in the thread.
            guard let id = welcomeThreadId else { return }
            let running = app.runningActions.contains { $0.hasPrefix(id) }
            if running { sawChipRun = true } else if sawChipRun { taskDone = true }
        case .sendFirst:
            if app.threads.keys.contains(where: { !threadsAtStart.contains($0) }) {
                finish()
                // On to what's left while the thread works.
                if app.setupShowsIcon { app.setupShown = true }
            }
        }
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

// MARK: - The Welcome thread

extension Tour {
    /// The example patch the Welcome folder gets. Its comment is for
    /// whoever opens the file to see what a patch looks like.
    static let welcomePatch = """
    // A patch: tools for the threads in this folder. This one adds a chip
    // above the composer that runs a command. A patch can also add panels
    // beside a thread and checks that run after each turn. You don't have
    // to write them: ask a thread to "add a button that runs the tests" and
    // its agent writes one like this.
    export default {
      icon: "dice",
      actions: [
        { title: "Roll a die", run: "echo \\"You rolled a $(( RANDOM % 6 + 1 )).\\"" },
      ],
    }

    """

    /// ~/Threadbear/Welcome: Threadbear's own folder, nowhere macOS asks
    /// about. A scripted dev app keeps it in its own data folder, away from
    /// the real one.
    @MainActor
    static func welcomeFolder(app: AppModel) -> String {
        #if DEBUG
        if Automation.instanceId != nil { return app.dataDir.appendingPathComponent("Welcome").path }
        #endif
        return NSString(string: "~/Threadbear/Welcome").expandingTildeInPath
    }

    /// Writes the example patch unless the file's there already (it may
    /// have been changed, and it's theirs now).
    nonisolated static func writeWelcomePatch(in folder: String) throws {
        let patches = URL(fileURLWithPath: folder).appendingPathComponent(".threadbear/patches")
        try FileManager.default.createDirectory(at: patches, withIntermediateDirectories: true)
        let file = patches.appendingPathComponent("welcome.ts")
        if !FileManager.default.fileExists(atPath: file.path) {
            try welcomePatch.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

extension AppModel {
    /// The Welcome thread for the tour's patch step: the one there is, or a
    /// new one with no turn (threads.create's `start: false`), opened in
    /// the inbox. Nil when the runner can't make one.
    func openTourWelcome() async -> String? {
        let folder = Tour.welcomeFolder(app: self)
        do {
            try Tour.writeWelcomePatch(in: folder)
        } catch {
            errorMessage = "Couldn't make the Welcome folder: \(error.localizedDescription)"
            return nil
        }
        sidebarMode = .inbox
        if let thread = threads.values.first(where: { $0.cwd == folder && !$0.isArchived }) {
            select(thread.id)
            return thread.id
        }
        guard let client else { return nil }
        do {
            let thread = try await client.createThread(NewThreadRequest(text: "", cwd: folder, title: "Welcome to Threadbear", start: false))
            threads[thread.id] = thread
            select(thread.id)
            return thread.id
        } catch {
            errorMessage = "Couldn't make the Welcome thread: \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - Drawing it

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
    /// Which view last said where the target is. A panel moved in the dock
    /// is drawn afresh: the new view says where it is before the old one
    /// disappears, so only the one that last said may clear it.
    @State private var me = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Tour.space)) } action: { frame in
                Tour.shared.frames[target] = CGRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: frame.height + bar)
                Tour.shared.framesFrom[target] = me
            }
            // A closed panel's frame would leave the tour lighting up
            // whatever took its place.
            .onDisappear {
                guard Tour.shared.framesFrom[target] == me else { return }
                Tour.shared.frames[target] = nil
            }
    }
}

/// What a hands-on step watches for.
private struct TourProgress: Equatable {
    var layout: DockLayout
    var running: Set<String>
    var threadCount: Int
}

/// The dimmed window with the step's part cut out of it, and the card.
/// Over RootView, in its `Tour.space`.
struct TourOverlay: View {
    @Environment(AppModel.self) private var app
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
                let shape = Spotlight(hole: hole ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
                ZStack(alignment: .topLeading) {
                    if step.task == .movePanel {
                        // The whole window takes the drag, drop targets and
                        // all, so this one only shades and never catches.
                        shape
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.3 : 0.18), style: FillStyle(eoFill: true))
                            .allowsHitTesting(false)
                    } else {
                        shape
                            // Darker in dark mode, where 0.4 barely showed
                            // against the dark panels.
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.35), style: FillStyle(eoFill: true))
                            // Clicks on the window behind wait until the
                            // tour's done, except in the lit part of a
                            // hands-on step (the chip, the composer).
                            .contentShape(step.task == nil ? AnyShape(Rectangle()) : AnyShape(shape), eoFill: step.task != nil)
                            .onTapGesture {}
                    }
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
                .animation(Juice.reduceMotion ? nil : .snappy(duration: 0.3), value: hole)
            }
            .transition(.opacity)
            .onAppear { tour.app = app }
            .onChange(of: TourProgress(layout: app.dock.layout, running: app.runningActions, threadCount: app.threads.count)) {
                tour.check()
            }
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
    /// A hands-on step that hasn't taken after `Tour.patience`: Next
    /// shows anyway, so nobody's stuck.
    @State private var waited = false

    var body: some View {
        let tour = Tour.shared
        let done = tour.taskDone
        VStack(alignment: .leading, spacing: zoomed(8)) {
            if let bear = step.bear {
                Image(nsImage: Bear.image(bear, side: zoomed(44)))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: zoomed(6)) {
                Text(step.title)
                    .font(.system(size: TypeScale.cardTitle + 1, weight: .semibold))
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .transition(Juice.popIn)
                }
            }
            Text(done ? step.doneBody ?? step.body : step.body)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
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
                if tour.skippable && step.task != .sendFirst {
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
                if step.task == .sendFirst {
                    // Sending is the way on; this leaves the message in the
                    // composer for later. No Return here: that's the send.
                    Button("Not now") { withAnimation(.easeOut(duration: 0.2)) { tour.finish() } }
                        .tip("End the tour. The message stays in the composer")
                } else {
                    Button(index == 0 ? "Show me" : "Next") { tour.next() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step.task != nil && !done && !waited)
                        .tip(step.task != nil && !done && !waited ? "Have a go first" : "The next step (Return)")
                }
            }
            .font(.system(size: TypeScale.label))
            .padding(.top, zoomed(4))
        }
        .padding(zoomed(16))
        .frame(width: zoomed(300), alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .animation(Juice.swap, value: done)
        .task(id: index) {
            waited = false
            try? await Task.sleep(for: Tour.patience)
            waited = true
        }
    }
}
