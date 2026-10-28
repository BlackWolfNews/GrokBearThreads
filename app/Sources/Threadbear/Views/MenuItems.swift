import AppKit

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
