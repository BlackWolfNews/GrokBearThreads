import AppKit
import SwiftUI

extension View {
    /// Runs `action` on a right-click or a Control-click on this view, for
    /// something other than a menu (the updates icon's popover). SwiftUI
    /// only has `.contextMenu` for these. Left clicks and hovers reach the
    /// view as before. `id` names it for the automation's right-click.
    func onRightClick(id: String? = nil, perform action: @escaping () -> Void) -> some View {
        background(RightClickAnchor(id: id, action: action).allowsHitTesting(false))
    }
}

private struct RightClickAnchor: NSViewRepresentable {
    let id: String?
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        view.action = action
    }
}

/// Behind the view and never hit, like the tips' anchors: a local monitor
/// sees every click first and acts on the ones that land on it. A
/// right-click carries on to the rest of the app afterwards (the tooltip
/// puts itself away on one); a Control-click stops here, or the button
/// under it would take it as a click too.
final class RightClickView: NSView {
    var action: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.takes(event, in: event.window) else { return event }
            self.action()
            return event.type == .rightMouseDown ? event : nil
        }
    }

    /// A right-click, or a Control-click, on this view in its own window.
    func takes(_ event: NSEvent, in eventWindow: NSWindow?) -> Bool {
        let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard secondary, let window, eventWindow === window, !isHiddenOrHasHiddenAncestor else { return false }
        // Both: visibleRect leaves out what a scroll view clips, but isn't
        // always kept inside the bounds (a window not on screen yet).
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
    }
}
