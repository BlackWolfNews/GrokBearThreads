import AppKit

/// Notes every menu the app opens in the app log (`log show --predicate
/// 'subsystem == "com.mikerosoft.threadbear"'`): where its window went, on
/// which screen, whether it was visible, and how it closed. Since macOS 27.2
/// (31 Oct) the app sometimes gets into a state where clicking the moon or a
/// composer chip shows no menu, though AppKit's own log says the menu's
/// window was made, and only a relaunch fixes it. These lines say whether
/// the menu was open somewhere unseen or closed straight away, and what was
/// in front at the time (ComputerCub was a suspect).
@MainActor
enum MenuWatch {
    private static var observers: [NSObjectProtocol] = []
    private static var opened: Date?
    private static var picked = false

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { began(menu) }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { ended(menu) }
        })
        observers.append(center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { picked = true }
        })
    }

    /// Top-level menus only: a submenu opening is part of the same click.
    private static func began(_ menu: NSMenu) {
        guard menu.supermenu == nil || menu.supermenu === NSApp.mainMenu else { return }
        opened = Date()
        picked = false
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let mouse = NSEvent.mouseLocation
        AppLog.write("menu", "opened \(describe(menu)), active \(NSApp.isActive), front \(front), mouse \(Int(mouse.x)),\(Int(mouse.y))")
        // Once its window is up. The main queue still runs while a menu
        // tracks the mouse (common modes), so this lands mid-menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard opened != nil else {
                AppLog.write("menu", "closed again within 0.25 s, before its window could be looked at")
                return
            }
            let windows = NSApp.windows.filter { $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue && $0.isVisible }
            if windows.isEmpty { AppLog.write("menu", "no visible menu window after 0.25 s") }
            for window in windows {
                let f = window.frame
                let screen = window.screen?.localizedName ?? "no screen"
                let onScreen = NSScreen.screens.contains { $0.frame.intersects(f) }
                AppLog.write("menu", "window \(type(of: window)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) on \(screen), on a screen \(onScreen), alpha \(window.alphaValue), occlusion visible \(window.occlusionState.contains(.visible))")
            }
        }
    }

    private static func ended(_ menu: NSMenu) {
        guard menu.supermenu == nil || menu.supermenu === NSApp.mainMenu, let start = opened else { return }
        opened = nil
        let seconds = String(format: "%.2f", Date().timeIntervalSince(start))
        AppLog.write("menu", "closed \(describe(menu)) after \(seconds) s, \(picked ? "an item picked" : "nothing picked")")
    }

    /// Its first items, enough to tell which menu it was.
    private static func describe(_ menu: NSMenu) -> String {
        let titles = menu.items.prefix(2).map(\.title).filter { !$0.isEmpty }
        return "\"\(menu.title)\" [\(titles.joined(separator: ", "))\(menu.items.count > 2 ? ", …" : "")]"
    }
}
