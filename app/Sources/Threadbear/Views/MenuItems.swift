import AppKit
import SwiftUI

extension NSMenuItem {
    /// A menu item with an SF Symbol beside its title. Every item in the
    /// app's own menus has one (MenuIconsTests), like the system's
    /// Copy and Paste.
    convenience init(title: String, symbol: String, action: Selector?, target: AnyObject? = nil) {
        self.init(title: title, action: action, keyEquivalent: "")
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.target = target
    }
}

/// Keeps the AppKit view behind a chip or button so its menu can open from
/// it. A plain Button that pops an NSMenu, rather than SwiftUI's `Menu`:
/// since macOS 27.2 a sidebar row's `Menu` (the Hibernate moon) took the
/// click and never opened (31 Oct).
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    private var popover: NSPopover?

    /// Opens above the chip, since the composer sits at the bottom of the
    /// window, or `below` it (a sidebar row's button); AppKit moves it if
    /// there isn't room.
    func popUp(_ menu: NSMenu, below: Bool = false) {
        guard let view else { return }
        // Menus have stopped showing in this run (MenuWatch): the popover
        // straight away.
        if MenuWatch.stuck {
            MenuPopover.show(menu, relativeTo: view.bounds, of: view, edge: below == view.isFlipped ? .maxY : .minY)
            return
        }
        MenuWatch.anchor = (view, below)
        defer { MenuWatch.anchor = nil }
        let gap = zoomed(4)
        let top = below
            ? (view.isFlipped ? view.bounds.height + gap : -gap)
            : (view.isFlipped ? -menu.size.height - gap : view.bounds.height + menu.size.height + gap)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: view)
    }

    /// A popover above the chip that goes away on a click outside or Esc.
    /// A second click on the chip while it's open closes it.
    func show(_ make: (@escaping () -> Void) -> NSViewController) {
        guard let view else { return }
        if let popover, popover.isShown {
            popover.close()
            return
        }
        if let window = view.window, let screen = window.screen ?? NSScreen.main {
            let chip = window.convertToScreen(view.convert(view.bounds, to: nil))
            AppWindow.roomAboveAnchor = screen.visibleFrame.maxY - chip.maxY
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = make { [weak popover] in popover?.close() }
        popover.contentViewController = controller
        // Measure the SwiftUI content first: shown before it knew its
        // height, the popover was placed for the wrong size and, once it
        // grew, slid down over the composer with Effort off the screen.
        popover.contentSize = controller.view.fittingSize
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Only there to position menus; clicks go to the chip on top.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// An NSMenuItem that runs a closure, for menus built in code.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
