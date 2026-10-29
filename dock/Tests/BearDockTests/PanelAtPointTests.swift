import AppKit
import Testing
@testable import BearDock

// Threadbear's activity log names the panel a click was in.

private final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

@MainActor @Test func aClickIsInTheFrontPanelOfTheGroupUnderIt() {
    _ = NSApplication.shared
    let c = DockController(layout: DockLayout(root: .split(DockSplit(id: "root", axis: .horizontal, children: [
        .group(DockGroup(id: "mid", panels: ["transcript"])),
        .group(DockGroup(id: "right", panels: ["highlights", "worktrees"], selected: "worktrees")),
    ]))))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let anchor = Flipped(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    window.contentView = anchor
    c.anchor = anchor
    c.frames = ["mid": CGRect(x: 0, y: 0, width: 600, height: 800), "right": CGRect(x: 600, y: 0, width: 400, height: 800)]
    // Window points go up from the bottom; the dock's go down from the top.
    #expect(c.panel(at: CGPoint(x: 300, y: 700), in: window) == "transcript")
    #expect(c.panel(at: CGPoint(x: 700, y: 100), in: window) == "worktrees")
    let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    #expect(c.panel(at: CGPoint(x: 10, y: 10), in: other) == nil)
}
