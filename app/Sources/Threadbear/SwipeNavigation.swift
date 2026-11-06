import AppKit
import SwiftUI
import ThreadbearCore
import WebKit

/// Trackpad swipes going back and forward, as in Safari: two fingers (or a
/// Magic Mouse's one) across the main window, when System Settings has
/// "Swipe between pages" on for scrolling, and three-finger swipes when
/// it's set to three fingers, which AppKit sends as swipe events instead.
/// The mouse's side buttons are `MouseNavigation`.
///
/// Like `RowSwipeController` it watches the app's scroll events, as
/// SwiftUI's gestures never see them. A sidebar row keeps a swipe left
/// (archive), and gives up a swipe right to Back while there's somewhere
/// to go back to (`takesBack`).
@MainActor
@Observable
final class SwipeNavigation {
    static let shared = SwipeNavigation()

    private(set) var swipe = NavigationSwipe()
    /// Set by `install`, or by a test.
    @ObservationIgnored weak var app: AppModel?
    /// System Settings' "Swipe between pages" with two fingers; a test's own.
    @ObservationIgnored var scrollSwipesOn: () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled }
    @ObservationIgnored private var monitor: Any?
    /// After a page swipe the trackpad keeps sending momentum events;
    /// they're ours too, or whatever's under the pointer would scroll.
    @ObservationIgnored private var eatingMomentum = false

    func install(app: AppModel) {
        guard monitor == nil else { return }
        self.app = app
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, in: event.window) ? nil : event
        }
    }

    /// Whether a swipe right goes Back just now: a row deciding what a
    /// swipe is asks, so the two never both take it.
    var takesBack: Bool {
        scrollSwipesOn() && (app?.canGoBack ?? false)
    }

    /// Whether the event was a page swipe's, and so has been dealt with.
    func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let app, let window, window === MainWindowFrame.window else { return false }
        if event.type == .swipe { return threeFingers(event, app: app) }
        if !event.momentumPhase.isEmpty {
            guard eatingMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { eatingMomentum = false }
            return true
        }
        // A mouse wheel has no phases, and Shift-scrolling one sideways
        // isn't a swipe.
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }
        if event.phase.contains(.began) {
            eatingMomentum = false
            guard scrollSwipesOn() else {
                swipe.reset()
                return false
            }
            swipe.begin(allowed: ways(at: event.locationInWindow, in: window, app: app))
        }
        if event.phase.contains(.began) || event.phase.contains(.changed) {
            // The fingers' way, right positive, whichever way the system
            // scrolls: with natural scrolling the delta already goes with them.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let wasArmed = swipe.armed
            let mine = withAnimation(nil) { swipe.move(dx: Double(event.scrollingDeltaX * sign), dy: Double(event.scrollingDeltaY)) }
            if swipe.armed != wasArmed {
                // A tick under the fingers on crossing the line, as a row's.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            return mine
        }
        if event.phase.contains(.ended) {
            eatingMomentum = swipe.direction != nil
            let to = withAnimation(.easeOut(duration: 0.15)) { swipe.end() }
            go(to, app: app)
            // Passed on even when it was ours: a row deciding alongside
            // needs its end too, to stop listening.
            return false
        }
        if event.phase.contains(.cancelled) {
            withAnimation(.easeOut(duration: 0.15)) { swipe.reset() }
            return false
        }
        return swipe.direction != nil
    }

    /// AppKit's swipe event, one per gesture: a positive deltaX is the
    /// fingers going left, which is Forward, as Safari has it.
    private func threeFingers(_ event: NSEvent, app: AppModel) -> Bool {
        if event.deltaX < 0, app.canGoBack { go(.back, app: app); return true }
        if event.deltaX > 0, app.canGoForward { go(.forward, app: app); return true }
        return false
    }

    private func go(_ direction: NavigationSwipe.Direction?, app: AppModel) {
        switch direction {
        case .back: app.goBack()
        case .forward: app.goForward()
        case nil: break
        }
    }

    /// The ways a swipe at `point` can go: somewhere in the history that
    /// way, and nothing under the pointer that scrolls sideways that way
    /// first (a wide table, a row of chips), as Safari leaves a wide page
    /// to scroll until it's at its edge. A web page in a panel keeps every
    /// swipe, as it scrolls (and goes back) by itself.
    private func ways(at point: NSPoint, in window: NSWindow, app: AppModel) -> Set<NavigationSwipe.Direction> {
        var ways: Set<NavigationSwipe.Direction> = []
        if app.canGoBack { ways.insert(.back) }
        // A row listening is under the pointer, and a swipe left is its.
        if app.canGoForward, RowSwipeController.listening == nil { ways.insert(.forward) }
        // The frame view has no superview, so the window's point is its own.
        var view = (window.contentView?.superview ?? window.contentView)?.hitTest(point)
        while let v = view, !ways.isEmpty {
            if v is WKWebView { return [] }
            if let scroll = v as? NSScrollView, let document = scroll.documentView {
                let shown = scroll.contentView.bounds
                if document.frame.width > shown.width + 1 {
                    if shown.minX > 0.5 { ways.remove(.back) }
                    if shown.maxX < document.frame.width - 0.5 { ways.remove(.forward) }
                }
            }
            view = v.superview
        }
        return ways
    }
}

/// The arrow at the window's edge while a page swipe is under way: it
/// slides in with the fingers and fills once letting go will go there.
struct SwipeNavigationArrow: View {
    private var swipe: NavigationSwipe { SwipeNavigation.shared.swipe }

    var body: some View {
        if let direction = swipe.direction {
            let back = direction == .back
            let armed = swipe.armed
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: zoomed(15), weight: .semibold))
                .foregroundStyle(armed ? Color.white : Color.secondary)
                .frame(width: zoomed(36), height: zoomed(36))
                .background(Circle().fill(armed ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(armed ? 0 : 0.1)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
                .scaleEffect(armed && !Juice.reduceMotion ? 1.08 : 1)
                .animation(Juice.hover, value: armed)
                // From just off the edge to 16 points in.
                .offset(x: (back ? 1 : -1) * (CGFloat(swipe.progress) * zoomed(52) - zoomed(36)))
                .opacity(min(1, swipe.progress * 3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: back ? .leading : .trailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
