import AppKit
import SwiftUI

/// For testing the real gestures without touching the mouse:
/// `BEARDOCK_EVENTS="down 1062 490;drag 640 420;esc;up;shot /tmp/x.png"`
/// sends real mouse and key events through the app, as if from the user.
/// Points are in the window's frame, top-left origin, as in a screenshot.
/// Steps: down x y | drag x y (in ten moves) | up | right x y | middle x y | esc | wait ms
/// | shot path (the window) | screen path (its area of the screen, menus included)
/// | others prefix (each of the app's other windows: a panel's own, the outline)
@MainActor
enum ScriptedEvents {
    /// The test window's own DemoView would start it again.
    private static var started = false

    static func run() async {
        guard !started, let script = ProcessInfo.processInfo.environment["BEARDOCK_EVENTS"] else { return }
        started = true
        try? await Task.sleep(for: .milliseconds(800))
        // A window of its own whose view takes the first click: the app
        // isn't active (it mustn't take focus from whatever Mike's doing), and
        // SwiftUI ignores clicks that only activate a window.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 790), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "BearDock test"
        window.contentView = FirstClickHostingView(rootView: AnyView(DemoView().preferredColorScheme(.dark)))
        window.orderFrontRegardless()
        NSApp.windows.filter { $0 !== window && $0.title == "BearDock" }.forEach { $0.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(600))
        var last = CGPoint.zero
        func point(_ x: String, _ y: String) -> CGPoint {
            CGPoint(x: Double(x) ?? 0, y: window.frame.height - (Double(y) ?? 0))
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            NSApp.sendEvent(e)
        }
        for step in script.split(separator: ";") {
            let a = step.split(separator: " ").map(String.init)
            switch a.first {
            case "down":
                last = point(a[1], a[2])
                mouse(.leftMouseDown, last)
            case "drag":
                let to = point(a[1], a[2])
                for i in 1...10 {
                    let t = Double(i) / 10
                    mouse(.leftMouseDragged, CGPoint(x: last.x + (to.x - last.x) * t, y: last.y + (to.y - last.y) * t))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                last = to
            case "up":
                mouse(.leftMouseUp, last)
            case "right":
                // Opens a menu, which runs its own loop: post it so this
                // script carries on (and can capture the menu) meanwhile.
                let p = point(a[1], a[2])
                if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    DispatchQueue.main.async { NSApp.sendEvent(e) }
                }
            case "middle":
                // A middle click, down and up. NSEvent can't make one with the
                // middle button's number, so it comes from a CGEvent (with no
                // window: its location is in screen points).
                let p = window.convertPoint(toScreen: point(a[1], a[2]))
                let global = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
                for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                    guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: .center) else { continue }
                    if let e = NSEvent(cgEvent: cg) { NSApp.sendEvent(e) }
                }
            case "screen":
                // The whole display the window's on, for menus (separate windows).
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R\(Int(window.frame.minX)),\(Int((NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY)),\(Int(window.frame.width)),\(Int(window.frame.height))", a[1]]
                try? p.run()
                p.waitUntilExit()
            case "esc":
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                            isARepeat: false, keyCode: 53) {
                    NSApp.sendEvent(e)
                }
            case "wait":
                try? await Task.sleep(for: .milliseconds(Int(a[1]) ?? 0))
            case "others":
                // Every other window of the app on screen (a panel's window
                // of its own, the outline of one), as <prefix>-1.png and on.
                let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.title != "BearDock" }
                for (i, w) in others.enumerated() {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", "\(a[1])-\(i + 1).png"]
                    try? p.run()
                    p.waitUntilExit()
                }
            case "shot":
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", a[1]]
                try? p.run()
                p.waitUntilExit()
            default:
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if ProcessInfo.processInfo.environment["BEARDOCK_QUIT"] != nil { NSApp.terminate(nil) }
    }
}

final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
