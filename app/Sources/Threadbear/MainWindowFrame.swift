import AppKit
import SwiftUI

/// Keeps the main window where Mike left it, across quits and the app's
/// own update restarts. SwiftUI reads the scene's autosaved frame
/// ("NSWindow Frame main") at launch, but with restoration off it never
/// wrote it again after the window moved, so every launch went back to a
/// stale frame (one a scripted run left behind). The app saves it itself,
/// under the same name, whenever the window moves or resizes.
@MainActor
enum MainWindowFrame {
    nonisolated static let defaultName = "main"
    private static var tracked: ObjectIdentifier?
    /// The main window, for things that only act on it (MouseNavigation).
    static weak var window: NSWindow?
    private static var observers: [NSObjectProtocol] = []

    /// Scripted runs size and place the window for their own ends; those
    /// frames aren't Mike's and must never be saved as his.
    static var scripted: Bool {
        let arguments = CommandLine.arguments
        return arguments.contains("--perf-run") || arguments.contains("--screenshots") || arguments.contains("--automation")
    }

    static func key(_ name: String) -> String { "Threadbear window frame \(name)" }

    static func track(_ window: NSWindow, name: String = defaultName, defaults: UserDefaults = .standard) {
        guard tracked != ObjectIdentifier(window) else { return }
        tracked = ObjectIdentifier(window)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // The exact frame, set by hand: AppKit's setFrameUsingName moved a
        // frame saved on the laptop's screen onto an external one.
        if let saved = defaults.string(forKey: key(name)) {
            let frame = NSRectFromString(saved)
            if onScreen(frame) { window.setFrame(frame, display: true) }
        }
        let save: @Sendable (Notification) -> Void = { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
                defaults.set(NSStringFromRect(window.frame), forKey: key(name))
                // SwiftUI places the window from this one at launch, so it
                // starts out in the right place too, before the above.
                window.saveFrame(usingName: name)
            }
        }
        for note in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: note, object: window, queue: .main, using: save))
        }
    }

    /// Mostly on a screen that's connected now: a frame left on a display
    /// that's gone would open the window where it can't be seen.
    static func onScreen(_ frame: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> Bool {
        guard frame.width >= 100, frame.height >= 100 else { return false }
        let area = frame.width * frame.height
        return screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width * overlap.height >= area / 2
        }
    }
}

/// Hands the main window to MainWindowFrame once it's in one.
struct MainWindowFrameTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MainWindowFrame.window = window
            if !MainWindowFrame.scripted { MainWindowFrame.track(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
