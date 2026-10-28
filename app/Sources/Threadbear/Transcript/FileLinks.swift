import AppKit
import ThreadbearCore

/// What a file link in the transcript can do, from its right-click menu.
/// The menu also sets which one a plain click does.
enum FileLinkAction: String, CaseIterable {
    /// Docs and pictures in the panel, anything else (code) in its app:
    /// how a click worked before there was a choice.
    case automatic
    case panel
    case app
    case finder

    private static let clickKey = "transcriptFileLinkClick"

    static var click: FileLinkAction {
        get { UserDefaults.standard.string(forKey: clickKey).flatMap(FileLinkAction.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: clickKey) }
    }

    /// The app macOS opens `path` in, for "Open in Xcode".
    static func appName(for path: String) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    func title(path: String?) -> String {
        switch self {
        case .automatic: return "Panel for Docs and Pictures, App for the Rest"
        case .panel: return "Open in Panel"
        case .app: return path.flatMap(Self.appName).map { "Open in \($0)" } ?? "Open in Default App"
        case .finder: return "Show in Finder"
        }
    }
}

/// The right-click menu on a file link: the ways to open it, Copy Path,
/// and "Click Opens", which sets what a plain click does.
@MainActor
final class FileLinkMenu: NSObject {
    let path: String?
    let open: (String, FileLinkAction) -> Void

    init(path: String?, open: @escaping (String, FileLinkAction) -> Void) {
        self.path = path
        self.open = open
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        guard let path else {
            let missing = NSMenuItem(title: "Couldn't Find This File", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
            return menu
        }
        let click = FileLinkAction.click
        for action in [FileLinkAction.panel, .app, .finder] {
            let item = NSMenuItem(title: action.title(path: path), action: #selector(openItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyPath), keyEquivalent: "")
        copy.target = self
        menu.addItem(.separator())
        menu.addItem(copy)
        menu.addItem(.separator())
        let defaults = NSMenu()
        for action in [FileLinkAction.automatic, .panel, .app, .finder] {
            // "Default App" rather than this file's app: the choice is for
            // every file link, and they open in different apps.
            let title = action == .app ? "Open in Default App" : action.title(path: path)
            let item = NSMenuItem(title: title, action: #selector(setClick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == click ? .on : .off
            defaults.addItem(item)
        }
        let submenu = NSMenuItem(title: "Click Opens", action: nil, keyEquivalent: "")
        submenu.submenu = defaults
        menu.addItem(submenu)
        // The menu holds its items' target weakly; keep this alive with it.
        objc_setAssociatedObject(menu, &FileLinkMenu.retainKey, self, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    nonisolated(unsafe) private static var retainKey: UInt8 = 0

    @objc private func openItem(_ item: NSMenuItem) {
        guard let path, let action = (item.representedObject as? String).flatMap(FileLinkAction.init(rawValue:)) else { return }
        open(path, action)
    }

    @objc private func setClick(_ item: NSMenuItem) {
        guard let action = (item.representedObject as? String).flatMap(FileLinkAction.init(rawValue:)) else { return }
        FileLinkAction.click = action
    }

    @objc private func copyPath() {
        guard let path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
