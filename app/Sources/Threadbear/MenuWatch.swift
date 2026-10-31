import AppKit

/// Notes every menu the app opens in the app log (`log show --predicate
/// 'subsystem == "com.mikerosoft.threadbear"'`): where its window went, on
/// which screen, whether it was visible, and how it closed. Since macOS 27.2
/// (31 Oct) a menu could be made and placed but never shown: the moon, the
/// composer chips and right-click menus all went dead until a relaunch. The
/// cause was the window left on the drag Space by a drag (DragSpace, 1 Nov).
///
/// It also works round it. A menu whose window isn't visible a quarter
/// second in is cancelled and drawn as a popover instead (`MenuPopover`).
/// When the window was on the drag Space it's taken off, and the next menu
/// shows as a menu. Anything else and, until the app relaunches, the
/// buttons' menus go straight to the popover.
@MainActor
enum MenuWatch {
    private static var observers: [NSObjectProtocol] = []
    private static var opened: Date?
    private static var picked = false
    /// Menus aren't showing in this run of the app, for a reason other than
    /// the drag Space.
    private(set) static var stuck = false
    /// The view a `MenuAnchor` is opening its menu from, so a fallback
    /// popover comes up from it rather than from the pointer, and who to
    /// tell it's open (`MenuAnchor.held`).
    static var anchor: (view: NSView, below: Bool, held: ((Bool) -> Void)?)?
    /// Between cancelling an unseen menu and its popover coming up.
    private(set) static var handingOver = false

    /// For the automation: as if menus had stopped showing, even a menu
    /// that does show.
    private static var forced = false
    static func forceStuck() { stuck = true; forced = true }

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
        // Once its window is up. A run-loop timer in the common modes, not
        // the main queue: it fires while the menu tracks the mouse even when
        // the menu was opened from a main-queue block, which the queue
        // can't interrupt (a scripted run hung that way, 31 Oct).
        later(0.25) {
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
            // The menu's own windows (not the tooltip panel, at the same
            // level): when stuck, none of them is ever shown. A working
            // menu's glass window is by now.
            let menuWindows = windows.filter { window in
                let name = String(describing: type(of: window))
                return name.contains("Menu") || name.contains("GlassEffect")
            }
            // Right-click menus land here every time once stuck (the
            // buttons' menus go straight to the popover, `MenuAnchor`): a
            // menu can only be cancelled once its tracking is well under way.
            guard menu.supermenu == nil, !menuWindows.isEmpty, forced || !menuWindows.contains(where: { $0.occlusionState.contains(.visible) }) else { return }
            fallBack(menu)
        }
    }

    /// Puts the invisible menu away and shows it as a popover, from the
    /// anchor it was opened from, else at the pointer.
    private static func fallBack(_ menu: NSMenu) {
        let from = anchor
        handingOver = true
        // Called a quarter second into the menu, from a timer: by then the
        // menu is tracking, and the cancel takes.
        menu.cancelTrackingWithoutAnimation()
        // Nearly always a window a drag left on the drag Space: taken off
        // it, the next menu shows. Anything else stays stuck for the run.
        // A held button now is the menu's own click (press, drag, release),
        // not a window being dragged.
        if !forced, DragSpace.repair("hidden menu", beforeMenu: true) {
            AppLog.write("menu", "not shown: its window was on the drag Space; this one opens as a popover, the next as a menu")
        } else {
            stuck = true
            AppLog.write("menu", "not shown: menus are stuck until the app relaunches, so they open as popovers")
        }
        // Once the menu's tracking has wound down and `popUp` has returned.
        later(0.05) {
            handingOver = false
            if let from, from.view.window != nil {
                MenuPopover.show(menu, relativeTo: from.view.bounds, of: from.view, edge: from.below == from.view.isFlipped ? .maxY : .minY) {
                    from.held?(false)
                }
            } else {
                from?.held?(false)
                MenuPopover.showAtPointer(menu)
            }
        }
    }

    private static func ended(_ menu: NSMenu) {
        guard menu.supermenu == nil || menu.supermenu === NSApp.mainMenu, let start = opened else { return }
        opened = nil
        let seconds = String(format: "%.2f", Date().timeIntervalSince(start))
        AppLog.write("menu", "closed \(describe(menu)) after \(seconds) s, \(picked ? "an item picked" : "nothing picked")")
    }

    /// Runs `body` after `seconds` on a common-modes timer (see `began`).
    private static func later(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Its first items, enough to tell which menu it was.
    private static func describe(_ menu: NSMenu) -> String {
        let titles = menu.items.prefix(2).map(\.title).filter { !$0.isEmpty }
        return "\"\(menu.title)\" [\(titles.joined(separator: ", "))\(menu.items.count > 2 ? ", …" : "")]"
    }
}
