import Foundation

/// A two-finger swipe across the window going back or forward, as Safari's
/// does: fingers to the right go back, to the left forward. Fed the
/// trackpad's scroll events by `SwipeNavigation` in the app; this decides
/// whether a gesture is a page swipe at all and how far along it is, so it
/// can be tested without a trackpad.
///
/// It shares the sidebar rows' gestures with `RowSwipe` (left on a row
/// archives), so it decides across or up and down by the same rule on the
/// same events, and the app only lets it have the way a row isn't using.
public struct NavigationSwipe: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case back, forward
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Fingers down, not yet clear which way.
        case deciding
        /// Across, a way there's somewhere to go: the events are ours.
        case tracking(Direction)
        /// Up and down, or across with nowhere to go that way: left alone.
        case ignoring
    }

    public private(set) var phase: Phase = .idle
    /// How far the fingers have gone the swipe's way since they touched.
    public private(set) var travel: Double = 0
    private var allowed: Set<Direction> = []
    private var sumX = 0.0
    private var sumY = 0.0
    private var lastDX = 0.0

    /// How far the fingers go before letting go goes there.
    public static let threshold = 110.0
    /// One last event this fast the swipe's way is a flick: it goes even
    /// short of the line, once it's `flickTravel` along.
    static let flickSpeed = 14.0
    static let flickTravel = 40.0

    public init() {}

    public var direction: Direction? {
        if case .tracking(let direction) = phase { return direction }
        return nil
    }

    /// 0 at the start, 1 at the line, for drawing the arrow.
    public var progress: Double { direction == nil ? 0 : min(1, max(0, travel / Self.threshold)) }

    /// Far enough along that letting go goes there.
    public var armed: Bool { direction != nil && travel >= Self.threshold }

    /// Fingers touched the trackpad, with the ways there's somewhere to go.
    public mutating func begin(allowed: Set<Direction>) {
        phase = .deciding
        travel = 0
        sumX = 0
        sumY = 0
        lastDX = 0
        self.allowed = allowed
    }

    /// The fingers moved (`dx` right positive, whichever way the system
    /// scrolls). Says whether the event is ours.
    public mutating func move(dx: Double, dy: Double) -> Bool {
        switch phase {
        case .idle, .ignoring:
            return false
        case .deciding:
            sumX += dx
            sumY += dy
            // RowSwipe's numbers, so a row and this always decide on the
            // same event and never both take a gesture.
            guard max(abs(sumX), abs(sumY)) >= RowSwipe.decideAfter else { return false }
            let way: Direction = sumX > 0 ? .back : .forward
            guard abs(sumX) >= abs(sumY) * RowSwipe.across, allowed.contains(way) else {
                phase = .ignoring
                return false
            }
            phase = .tracking(way)
            travel = abs(sumX)
            lastDX = dx
            return true
        case .tracking(let way):
            let along = way == .back ? dx : -dx
            travel = max(0, travel + along)
            lastDX = along
            return true
        }
    }

    /// The fingers lifted: where to go, if anywhere.
    public mutating func end() -> Direction? {
        defer { reset() }
        guard let direction else { return nil }
        if travel >= Self.threshold { return direction }
        return lastDX >= Self.flickSpeed && travel >= Self.flickTravel ? direction : nil
    }

    public mutating func reset() {
        phase = .idle
        travel = 0
    }
}
