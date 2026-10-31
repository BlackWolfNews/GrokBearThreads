import AppKit

/// Works round a macOS 27.2 window server bug that left every menu opened
/// from Threadbear's window invisible until a relaunch (30 Oct to 1 Nov:
/// the moon, the access chip, right-click menus).
///
/// While a window is dragged the window server also puts it on a hidden
/// drag Space (31 on Mike's Mac), and takes it off again when the drag
/// ends. On 27.2, when the drag also moves the window onto the Space of the
/// display it's on, it's left on the drag Space for good. A window ends up
/// filed under another display's Space when the app starts in the
/// background with Mike on another screen, as a restart into an update
/// does. From then on the Dock puts every menu opened from that window onto
/// the drag Space too, and that Space is only drawn on the display of the
/// last drag, so menus open invisibly as soon as anything is dragged on
/// another display. Popovers still showed: they're child windows, on the
/// window's own Space as well. Reordering the window, moving it between
/// displays or changing its collection behaviour doesn't take it off the
/// drag Space; only closing the window did, hence "a relaunch fixes it".
///
/// So the app takes its own windows off any Space that isn't one of the
/// displays' own: before a button opens a menu, after a window moves, on
/// activation, and every few seconds, never mid-drag. The window server
/// calls are private (SkyLight, looked up at run time); without them this
/// does nothing. A test app showed it: on the drag Space its menus were made
/// and ordered in but never drawn, every time, and drawn again once it was
/// taken off (1 Nov).
@MainActor
enum DragSpace {
    private static var installed = false
    private static var timer: Timer?
    private static var moved: DispatchWorkItem?
    /// How many times a window was found left on a drag Space and taken off,
    /// for the automation's dump.
    private(set) static var repairs = 0

    static func install() {
        guard !installed, SkyLight.available else { return }
        installed = true
        let center = NotificationCenter.default
        // A drag ends with the window moved: look once the button's up.
        center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                // Not the tooltip panel, which moves with every tip.
                guard let window = note.object as? NSWindow, isTopLevel(window) else { return }
                soon("moved")
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { repair("active") }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { soon("displays changed") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { soon("space changed") }
        }
        // A backstop for right-click menus, which open with no warning. One
        // window server call per window, so cheap.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { repair("timer") } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        repair("launch")
    }

    /// Half a second on, so a drag that's still settling isn't touched.
    private static func soon(_ reason: String) {
        moved?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { repair(reason) } }
        moved = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Takes the app's own top-level windows off any Space that isn't a
    /// display's own. True when one was found there. `beforeMenu`: a button
    /// is about to open a menu, so a held mouse button is that click, not a
    /// window being dragged.
    @discardableResult
    static func repair(_ reason: String, beforeMenu: Bool = false) -> Bool {
        guard SkyLight.available else { return false }
        // Mid-drag the window belongs on the drag Space; the move afterwards
        // brings us back.
        guard beforeMenu || NSEvent.pressedMouseButtons == 0 else {
            if reason != "timer" { soon(reason) }
            return false
        }
        let displaySpaces = SkyLight.displaySpaces()
        guard !displaySpaces.isEmpty else { return false }
        var found = false
        for window in NSApp.windows where isTopLevel(window) {
            let spaces = SkyLight.spaces(of: window.windowNumber)
            let stray = strays(windowSpaces: spaces, displaySpaces: displaySpaces)
            guard !stray.isEmpty else { continue }
            SkyLight.remove(window.windowNumber, from: stray)
            found = true
            repairs += 1
            let after = SkyLight.spaces(of: window.windowNumber)
            AppLog.write("menu", "window \(window.windowNumber) (\(window.title.isEmpty ? String(describing: type(of: window)) : "\"\(window.title)\"")) was left on Space \(stray) after a drag (macOS 27.2), so its menus wouldn't show; took it off (\(reason)), now on \(after)")
        }
        return found
    }

    /// The Spaces a window is on that no display has: the drag Space a drag
    /// left it on. Taken off it, a window goes back to its display's Space
    /// even if that was all it was on.
    nonisolated static func strays(windowSpaces: [Int], displaySpaces: Set<Int>) -> [Int] {
        windowSpaces.filter { !displaySpaces.contains($0) }
    }

    /// The main window, Settings, a review's window: not menus, tooltips or
    /// popovers (child windows, which go where their parent goes).
    private static func isTopLevel(_ window: NSWindow) -> Bool {
        window.isVisible && window.parent == nil && window.level.rawValue < NSWindow.Level.popUpMenu.rawValue
            && window.windowNumber > 0
    }
}

/// The few private window server calls `DragSpace` needs, looked up by name
/// so a macOS without them leaves the app working, just unrepaired.
@MainActor
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias RemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let copySpaces = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let copyDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let removeFromSpaces = symbol("CGSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpaces.self)
    private static let addToSpaces = symbol("CGSAddWindowsToSpaces", as: AddWindowsToSpaces.self)

    static var available: Bool {
        mainConnection != nil && copySpaces != nil && copyDisplaySpaces != nil && removeFromSpaces != nil
    }

    /// Every Space of every display, Desktops and full-screen apps alike.
    static func displaySpaces() -> Set<Int> {
        guard let mainConnection, let copyDisplaySpaces,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids = Set<Int>()
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["ManagedSpaceID"] as? Int { ids.insert(id) }
            }
            if let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int { ids.insert(current) }
        }
        return ids
    }

    /// The Spaces a window is on, the system's own included (mask 0xFF;
    /// a narrower one leaves the drag Space out).
    static func spaces(of window: Int) -> [Int] {
        guard let mainConnection, let copySpaces,
              let spaces = copySpaces(mainConnection(), 0xFF, [window] as CFArray)?.takeRetainedValue() as? [Int] else { return [] }
        return spaces
    }

    static func remove(_ window: Int, from spaces: [Int]) {
        guard let mainConnection, let removeFromSpaces else { return }
        removeFromSpaces(mainConnection(), [window] as CFArray, spaces as CFArray)
    }

    /// For the automation: puts a window on a Space, as a drag on 27.2 leaves
    /// one on the drag Space.
    static func add(_ window: Int, to spaces: [Int]) {
        guard let mainConnection, let addToSpaces else { return }
        addToSpaces(mainConnection(), [window] as CFArray, spaces as CFArray)
    }
}
