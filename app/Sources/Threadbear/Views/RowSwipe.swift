import AppKit
import SwiftUI
import ThreadbearCore

/// What a two-finger swipe left on a row does: archive it, or in the
/// Archive view put it back.
struct RowSwipeAction {
    var icon: String
    /// Asked once the fingers lift past the line, before the row goes:
    /// false (a busy thread, and Mike said Cancel) springs it back.
    var confirm: () -> Bool = { true }
    var run: () -> Void

    @MainActor
    static func forRow(_ thread: ThreadSummary, mode: SidebarMode, app: AppModel) -> RowSwipeAction? {
        if mode.rowActions.contains(.archive) {
            return RowSwipeAction(icon: "archivebox",
                                  confirm: { BusyConfirm.allowed(.archive, threadId: thread.id, app: app) },
                                  run: { app.archive(thread.id) })
        }
        if mode.rowActions.contains(.unarchive) {
            return RowSwipeAction(icon: "arrow.uturn.backward", run: { app.unarchive(thread.id) })
        }
        return nil
    }
}

/// Feeds a row's `RowSwipe` the trackpad's scroll events. SwiftUI on the
/// Mac has no swipe actions outside a `List` (and the sidebar isn't one,
/// see `ThreadList`), and its gestures never see scrolling, so this
/// watches the app's scroll events while the pointer is over the row,
/// as Mail's list does. Only one row is hovered at a time, so only one
/// of these is listening.
@MainActor
@Observable
final class RowSwipeController {
    private(set) var swipe = RowSwipe()
    /// Set once the row is on its way off, so it stays there.
    private(set) var leaving = false
    @ObservationIgnored var action: RowSwipeAction?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var hovered = false
    /// After a swipe, the trackpad keeps sending momentum events; they're
    /// the row's too, or the list would scroll once the fingers lift.
    @ObservationIgnored private var eatingMomentum = false

    var offset: CGFloat { leaving ? -swipe.width - 40 : CGFloat(swipe.offset) }
    var isSwiping: Bool { swipe.isSwiping || leaving }

    func setWidth(_ width: CGFloat) { swipe.width = Double(width) }

    /// Listens while the pointer's over the row, and through to the end of
    /// a swipe it started even if the pointer's no longer there.
    func setHovered(_ hovering: Bool) {
        hovered = hovering
        updateMonitor()
    }

    /// The row listening, for scripted swipes.
    static weak var listening: RowSwipeController?

    /// The row's gone: stop listening whatever it was doing.
    func stop() {
        hovered = false
        dragLast = nil
        eatingMomentum = false
        swipe.cancel()
        updateMonitor()
    }

    private func updateMonitor() {
        let wanted = action != nil && (hovered || swipe.phase != .idle || eatingMomentum)
        if wanted { Self.listening = self } else if Self.listening === self { Self.listening = nil }
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Whether the event was the row's.
    func handle(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            guard eatingMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                eatingMomentum = false
                updateMonitor()
            }
            return true
        }
        // A mouse wheel has no phases (and Shift-scrolling one sideways
        // isn't a swipe); a trackpad or Magic Mouse does.
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }
        if event.phase.contains(.began) {
            guard hovered, !leaving else { return false }
            swipe.begin()
            eatingMomentum = false
        }
        if event.phase.contains(.changed) || event.phase.contains(.began) {
            // Follow the fingers whichever way the system scrolls: with
            // natural scrolling the delta already goes the fingers' way.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            return move(dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY)
        }
        if event.phase.contains(.ended) {
            let wasSwiping = swipe.isSwiping
            let archive = swipe.end()
            eatingMomentum = wasSwiping
            if archive { finish() } else { springBack() }
            updateMonitor()
            return wasSwiping
        }
        if event.phase.contains(.cancelled) {
            let wasSwiping = swipe.isSwiping
            swipe.cancel()
            springBack()
            updateMonitor()
            return wasSwiping
        }
        return swipe.isSwiping
    }

    private func move(dx: CGFloat, dy: CGFloat) -> Bool {
        let wasArmed = swipe.armed
        let mine = withAnimation(nil) { swipe.move(dx: Double(dx), dy: Double(dy)) }
        if swipe.armed != wasArmed {
            // A tick under the fingers on crossing the line, either way.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return mine
    }

    /// Where the mouse was last time it moved with the button down: a mouse
    /// has no two-finger swipe, so dragging the row left does the same.
    @ObservationIgnored private var dragLast: CGSize?

    /// The mouse moved with the button down on the row, `translation` from
    /// where it went down (in a space that doesn't move with the row).
    func drag(_ translation: CGSize) {
        guard action != nil, !leaving, swipe.phase == .idle || dragLast != nil else { return }
        if dragLast == nil {
            swipe.begin()
            dragLast = .zero
        }
        let last = dragLast ?? .zero
        dragLast = translation
        _ = move(dx: translation.width - last.width, dy: translation.height - last.height)
    }

    /// The mouse button came up.
    func dragEnded() {
        guard dragLast != nil else { return }
        dragLast = nil
        // A plain click never left `deciding`: nothing to spring back.
        guard swipe.isSwiping else { return swipe.reset() }
        if swipe.end() { finish() } else { springBack() }
    }

    private func springBack() {
        withAnimation(Juice.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.75)) {
            swipe.reset()
        }
    }

    private func finish() {
        guard let action else { return springBack() }
        // Hold where it was let go while a busy thread asks first.
        guard action.confirm() else { return springBack() }
        Whoosh.play()
        withAnimation(.easeIn(duration: Juice.reduceMotion ? 0.1 : 0.16)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Juice.reduceMotion ? 100 : 160))
            action.run()
            // Normally the row's gone by now. If it's still drawn (a list
            // that keeps archived threads), bring it back into place.
            try? await Task.sleep(for: .milliseconds(600))
            leaving = false
            swipe.reset()
        }
    }

}

/// Trackpad scroll events made up for scripted swipes.
enum RowSwipeEvents {
    enum Phase: Int64 {
        // CGScrollPhase's values.
        case began = 1, changed = 2, ended = 4
    }

    /// `dx` is the fingers' way, left negative, whichever way the
    /// system's scrolling runs.
    static func event(dx: Double, phase: Phase) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        guard let probe = NSEvent(cgEvent: cg) else { return nil }
        let delta = probe.isDirectionInvertedFromDevice ? dx : -dx
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            cg.location = CGPoint(x: window.frame.minX + 100, y: (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY + 200)
        }
        return NSEvent(cgEvent: cg)
    }
}

extension View {
    /// Slides the row with the fingers and shows what letting go will do
    /// in the space it leaves on the right.
    func rowSwipe(_ controller: RowSwipeController) -> some View {
        modifier(RowSwipeModifier(controller: controller))
    }
}

private struct RowSwipeModifier: ViewModifier {
    let controller: RowSwipeController

    func body(content: Content) -> some View {
        content
            .offset(x: controller.offset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controller.setWidth($0) }
            // Behind the row and only as wide as the gap it's left: the
            // rows have no fill of their own, so a full-width backing would
            // show through the text.
            .background(alignment: .trailing) {
                if let action = controller.action, controller.offset < 0 {
                    let armed = controller.swipe.armed || controller.leaving
                    ZStack {
                        RoundedRectangle(cornerRadius: SidebarMetrics.corner)
                            .fill(armed ? Color.accentColor : Color.primary.opacity(0.07))
                        Image(systemName: action.icon)
                            .font(.system(size: zoomed(14), weight: .medium))
                            .foregroundStyle(armed ? Color.white : Color.secondary)
                            .scaleEffect(armed && !Juice.reduceMotion ? 1.12 : 1)
                            // Hidden until there's room for it.
                            .opacity(min(1, max(0, (-controller.offset - zoomed(16)) / zoomed(24))))
                    }
                    .frame(width: -controller.offset)
                    .animation(Juice.hover, value: armed)
                    .accessibilityHidden(true)
                }
            }
    }
}
