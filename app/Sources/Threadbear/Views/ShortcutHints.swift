import AppKit
import Observation
import SwiftUI

/// Holding ⌘ shows each button's key beside the button, as Tandem does, so
/// the keys can be learned at a glance instead of being printed on the
/// buttons all the time (Mike didn't want "⌘N" sitting on New thread).
///
/// The keys show the moment ⌘ goes down on its own and go the moment it's
/// let go or used: a shortcut, a ⌘-click or a ⌘-scroll hides them, and they
/// don't come back until ⌘ is pressed again.
@MainActor
@Observable
final class ShortcutHints {
    static let shared = ShortcutHints()

    /// True while the keys are on show.
    private(set) var showing = false

    /// Overridable for tests: the app is frontmost, a mouse button is down.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// ⌘ was used for something since it went down.
    @ObservationIgnored private var spent = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// Watches the app's events. Called once at launch.
    func install() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            MainActor.assumeIsolated { ShortcutHints.shared.handle(event) }
            return event
        }
        // ⌘-Tab away lets ⌘ go in the other app, so this app never hears it.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutHints.shared.reset() }
        }
    }

    func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.type {
        case .flagsChanged:
            if !flags.contains(.command) {
                reset()
            } else if flags == .command {
                if !spent && !showing && isAppActive() && !isMouseDown() { showing = true }
            } else {
                // ⌘ with Shift or Option: a chord on its way.
                spent = true
                hide()
            }
        default:
            // A key, a click or a scroll: whatever ⌘ is down for, it isn't
            // for looking at the keys.
            if flags.contains(.command) { spent = true }
            hide()
        }
    }

    /// The automation's `hints` command: the keys as if ⌘ were held, for a
    /// screenshot (a script can't hold a key down in the app).
    func setShowing(_ on: Bool) {
        spent = false
        showing = on
    }

    /// Back to nothing held.
    func reset() {
        spent = false
        hide()
    }

    private func hide() {
        if showing { showing = false }
    }
}

/// Where a key goes, relative to its button.
enum ShortcutHintPlacement {
    /// Just right of the button, over whatever is there (the activity bar's
    /// icons, whose neighbours above and below are too close).
    case after
    /// Just left of the button (the composer's Stop, at the window's edge,
    /// and New thread, at the sidebar's).
    case before
}

extension View {
    /// Shows `key` (e.g. "⌘N") by the view while ⌘ is held. Nothing for nil.
    /// Drawn as an overlay, so it never moves anything; a key that hangs
    /// outside its button needs the button drawn after its neighbours
    /// (`zIndex`) to stay on top of them.
    func shortcutHint(_ key: String?, _ placement: ShortcutHintPlacement) -> some View {
        modifier(ShortcutHintMark(key: key, placement: placement))
    }
}

private struct ShortcutHintMark: ViewModifier {
    let key: String?
    let placement: ShortcutHintPlacement

    func body(content: Content) -> some View {
        let gap = zoomed(4)
        content.overlay(alignment: placement == .before ? .leading : .trailing) {
            if ShortcutHints.shared.showing, let key {
                switch placement {
                case .after:
                    // A zero-wide frame on the button's trailing edge, with
                    // the key hanging out of it to the right. (An alignment
                    // guide moved it only halfway, onto the icon.)
                    ShortcutKeyBadge(key: key)
                        .frame(width: 0, alignment: .leading)
                        .offset(x: gap)
                case .before:
                    ShortcutKeyBadge(key: key)
                        .frame(width: 0, alignment: .trailing)
                        .offset(x: -gap)
                }
            }
        }
    }
}

/// A key as the hints draw it: dark text on amber, Tandem's colours, so it
/// reads as a passing label over the UI rather than part of it.
struct ShortcutKeyBadge: View {
    static let amber = Color(red: 1, green: 0xB2 / 255, blue: 0x24 / 255)
    static let onAmber = Color(red: 0x0C / 255, green: 0x0D / 255, blue: 0x0F / 255)

    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: zoomed(10.5), weight: .semibold))
            .foregroundStyle(Self.onAmber)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, zoomed(4))
            .padding(.vertical, zoomed(1))
            .background(RoundedRectangle(cornerRadius: zoomed(4)).fill(Self.amber))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
