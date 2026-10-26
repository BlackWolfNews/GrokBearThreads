import AppKit
import SwiftUI
import ThreadbareCore

/// The row under the composer's text: "+" for images, the folder, account,
/// model and permission chips, and send (or Stop) on the right.
struct ComposerControls: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary?
    let running: Bool
    let canSend: Bool
    let onAttach: () -> Void
    let onSend: () -> Void

    var body: some View {
        let settings = ThreadSettings(app: app, thread: thread)
        let cwd = settings.cwd
        let account = settings.account
        let model = settings.model
        let ask = settings.ask
        HStack(spacing: 4) {
            PlusButton(action: onAttach)
                // Pulls the glyph back so it lines up with the text above.
                .padding(.leading, -7)
            ComposerChip(icon: "folder", title: ComposerChips.folder(cwd), help: cwd.abbreviatingHome) {
                settings.folderMenu()
            }
            ChipDivider()
            ComposerChip(icon: "person.crop.circle", title: app.accountShortTitle(account), help: app.accountTitle(account)) {
                settings.accountMenu()
            }
            ChipDivider()
            ComposerChip(icon: "sparkle", title: ComposerChips.model(model), help: model ?? "The account's default model") {
                settings.modelMenu()
            }
            ChipDivider()
            ComposerChip(
                icon: ask ? "lock" : "lock.open",
                title: ask ? "Ask before edits" : "Full access",
                help: ask ? "Asks before editing files or running commands" : "Edits files and runs commands without asking"
            ) {
                settings.permissionMenu()
            }
            Spacer(minLength: 8)
            SendButton(running: running, canSend: canSend, onSend: onSend, onStop: { app.interrupt() })
                .layoutPriority(1)
        }
        .frame(height: SendButton.size)
    }
}

/// The folder, account, model and permission for the open thread, or the
/// settings the next new thread starts with, and the menus that change them.
/// Menus are built when a chip is clicked, so the composer doesn't redraw
/// whenever any thread in the list changes.
@MainActor
private struct ThreadSettings {
    let app: AppModel
    let thread: ThreadSummary?

    var cwd: String { thread?.cwd ?? app.newThreadCwd ?? app.defaults.cwd }
    var account: String { thread?.accountId ?? app.newThreadAccount ?? app.lastAccountId }
    var model: String? { thread == nil ? app.newThreadModel : thread?.model }
    var ask: Bool { thread.map { $0.permissionMode == .ask } ?? app.newThreadAsk }

    func folderMenu() -> NSMenu {
        let menu = NSMenu()
        let current = cwd
        for folder in recentFolders(including: current) {
            menu.addItem(ActionMenuItem(folder.abbreviatingHome, checked: folder == current) { setCwd(folder) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Choose…") { chooseFolder() })
        return menu
    }

    func accountMenu() -> NSMenu {
        let menu = NSMenu()
        let current = account
        for item in app.accounts {
            menu.addItem(ActionMenuItem(item.title, checked: item.id == current) { setAccount(item.id) })
        }
        if app.accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    func modelMenu() -> NSMenu {
        let menu = NSMenu()
        let current = model
        let fallback = ActionMenuItem("Default", checked: current == nil) { setModel(nil) }
        fallback.subtitle = "Whatever the account is set to use"
        menu.addItem(fallback)
        menu.addItem(.separator())
        for name in ["opus", "sonnet", "haiku"] {
            menu.addItem(ActionMenuItem(name.capitalized, checked: current == name) { setModel(name) })
        }
        // A model set some other way (a full id) still shows, ticked.
        if let current, !["opus", "sonnet", "haiku"].contains(current) {
            menu.addItem(ActionMenuItem(current, checked: true) { setModel(current) })
        }
        return menu
    }

    func permissionMenu() -> NSMenu {
        let menu = NSMenu()
        let full = ActionMenuItem("Full access", checked: !ask) { setAsk(false) }
        full.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil)
        full.subtitle = "Edits files and runs commands without asking"
        let askItem = ActionMenuItem("Ask before edits", checked: ask) { setAsk(true) }
        askItem.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        askItem.subtitle = "Asks before editing files or running commands"
        menu.addItem(full)
        menu.addItem(askItem)
        return menu
    }

    private func recentFolders(including cwd: String) -> [String] {
        var seen = Set<String>()
        var folders: [String] = []
        for folder in [cwd, app.defaults.cwd] + app.threads.values.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }).map(\.cwd) {
            guard !folder.isEmpty, seen.insert(folder).inserted else { continue }
            folders.append(folder)
            if folders.count >= 8 { break }
        }
        return folders
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: cwd)
        if panel.runModal() == .OK, let url = panel.url { setCwd(url.path) }
    }

    private func setCwd(_ folder: String) {
        if let thread { app.setCwd(thread.id, folder) } else { app.newThreadCwd = folder }
    }

    private func setAccount(_ id: String) {
        if let thread { app.setAccount(thread.id, id) } else { app.newThreadAccount = id }
    }

    private func setModel(_ model: String?) {
        if let thread { app.setModel(thread.id, model) } else { app.newThreadModel = model }
    }

    private func setAsk(_ ask: Bool) {
        if let thread { app.setPermission(thread.id, ask: ask) } else { app.newThreadAsk = ask }
    }
}

/// A quiet menu chip: icon, short label and a small chevron in secondary
/// colours, a faint fill on hover, and an AppKit menu that opens above it.
/// SwiftUI's `Menu` on macOS ignores label colours and sizes, which is why
/// the old chips came out as bright as the message text.
private struct ComposerChip: View {
    let icon: String
    let title: String
    let help: String
    let menu: () -> NSMenu
    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ChipDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 12)
    }
}

private struct PlusButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add images")
        .accessibilityLabel("Add images")
    }
}

/// A 28 pt circle: filled with the text colour when there's something to
/// send (or a turn to stop), faint and empty-looking when there isn't.
private struct SendButton: View {
    let running: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    static let size: CGFloat = 28

    var body: some View {
        if running {
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(CircleButtonStyle(filled: true))
            .help("Stop (⌘.)")
            .accessibilityLabel("Stop")
            .keyboardShortcut(".", modifiers: .command)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(CircleButtonStyle(filled: canSend))
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
    }
}

private struct CircleButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? AnyShapeStyle(.background) : AnyShapeStyle(.tertiary))
            .frame(width: SendButton.size, height: SendButton.size)
            .background(Circle().fill(filled ? Color.primary : Color.primary.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// Keeps the AppKit view behind a chip so its menu can open from it.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    /// Opens above the chip, since the composer sits at the bottom of the
    /// window; AppKit moves it if there isn't room.
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let gap: CGFloat = 4
        let top = view.isFlipped ? -menu.size.height - gap : view.bounds.height + menu.size.height + gap
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
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
private final class ActionMenuItem: NSMenuItem {
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
