import AppKit

extension NSWindow {
    /// For a scripted or screenshot run's windows, which happen while Mike is
    /// working. One level below normal keeps a window under every app's
    /// windows even if he clicks it, and out of his taskbar, which lists
    /// level 0 windows whether or not their app is in the Dock (he couldn't
    /// tell one from his real Threadbare window there). `screencapture -l`
    /// still captures it by id at any level, covered or not.
    func tuckBehind() {
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        orderBack(nil)
    }
}
