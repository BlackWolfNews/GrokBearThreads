import AppKit
import SwiftUI
import ThreadbareCore

/// The row under the composer's text: "+" (images and the folder), the
/// folder chip when it isn't the default one, the account, model and
/// permission chips, and send (or Stop) on the right.
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
        let ask = settings.ask
        HStack(spacing: 4) {
            PlusButton { settings.plusMenu(attach: onAttach) }
                // Pulls the glyph back so it lines up with the text above.
                .padding(.leading, -7)
            if ComposerChips.showsFolder(cwd, defaultFolder: app.defaults.cwd) {
                ComposerChip(icon: "folder", title: ComposerChips.folder(cwd), help: cwd.abbreviatingHome) {
                    settings.folderMenu()
                }
                ChipDivider()
            }
            ComposerChip(icon: "person.crop.circle", title: app.accountShortTitle(account), help: app.accountTitle(account)) {
                settings.accountMenu()
            }
            ChipDivider()
            ComposerChip(icon: "sparkle", title: settings.modelChipTitle, help: settings.modelChipHelp) {
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
struct ThreadSettings {
    let app: AppModel
    let thread: ThreadSummary?

    var cwd: String { thread?.cwd ?? app.newThreadCwd ?? app.defaults.cwd }
    var account: String { thread?.accountId ?? app.newThreadAccount ?? app.lastAccountId }
    var model: String? { thread == nil ? app.newThreadModel : thread?.model }
    var effort: String? { thread == nil ? app.newThreadEffort : thread?.effort }
    var ask: Bool { thread.map { $0.permissionMode == .ask } ?? app.newThreadAsk }

    /// What the account's CLI offers, once the runner has asked it.
    var choices: [ModelChoice] { app.account(account)?.models ?? [] }

    /// The model a thread with none of its own runs on: the runner's
    /// default for a new thread, else the account's. For an open thread the
    /// last turn is the truth, and it already includes the runner's default.
    var defaultModel: String? {
        if let thread { return ComposerChips.resolvedModel(thread.modelInUse, app.account(thread.accountId)?.defaultModel) }
        return ComposerChips.resolvedModel(app.defaults.model, app.account(account)?.defaultModel)
    }

    /// The model the chip shows, resolved; nil only before the runner has
    /// said anything.
    var effectiveModel: String? { ComposerChips.resolvedModel(model, defaultModel) }

    /// The level the chip shows: the one chosen, else what the CLI said it
    /// ran the last turn at.
    var effectiveEffort: String? { effort ?? thread?.effortInUse }

    var modelChipTitle: String { ComposerChips.chipTitle(model: effectiveModel, effort: effectiveEffort, choices: choices) }

    var modelChipHelp: String {
        var parts: [String] = []
        if let model { parts.append(model) } else if let defaultModel { parts.append("\(defaultModel), the default") } else { parts.append("The account's default model") }
        if let effort { parts.append("\(ComposerChips.effortTitle(effort).lowercased()) effort") }
        else if let level = thread?.effortInUse { parts.append("\(level) effort, the model's own level") }
        else { parts.append("the model's own effort level") }
        return parts.joined(separator: ", ")
    }

    /// "+": images, and the folder, which has no chip of its own while it's
    /// the default.
    func plusMenu(attach: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        let images = ActionMenuItem("Attach images…", handler: attach)
        images.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        menu.addItem(images)
        let folder = NSMenuItem(title: "Folder", action: nil, keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.submenu = folderMenu()
        menu.addItem(folder)
        return menu
    }

    func folderMenu() -> NSMenu {
        let menu = NSMenu()
        let current = cwd
        for folder in recentFolders(including: current) {
            let item = ActionMenuItem(folder.abbreviatingHome, checked: folder == current) { setCwd(folder) }
            if !ComposerChips.showsFolder(folder, defaultFolder: app.defaults.cwd) { item.subtitle = "Default" }
            menu.addItem(item)
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

    /// The models by name, the default one starred, then the effort level.
    /// Picking the default row leaves the thread on the default (so it
    /// follows the account's setting), any other pins that model.
    func modelMenu() -> NSMenu {
        let menu = NSMenu()
        let effective = effectiveModel
        let defaultId = defaultModel
        // The CLI's list once known; the three aliases until then.
        let known = choices.isEmpty ? ["opus", "sonnet", "haiku"].map { ModelChoice(id: $0, model: $0, title: ComposerChips.model($0)) } : choices
        // The picker's main rows: the aliases (a word), and whatever the
        // default is. Dated and old full ids go under "Older models".
        let isMain = { (c: ModelChoice) -> Bool in
            c.id.allSatisfy(\.isLetter) || Self.matches(c, defaultId) || Self.matches(c, effective)
        }
        var main = known.filter(isMain)
        let older = known.filter { !isMain($0) }
        if let effective, !known.contains(where: { Self.matches($0, effective) }) {
            // A model set some other way (a full id) still shows, ticked.
            main.append(ModelChoice(id: effective, model: effective, title: ComposerChips.model(effective)))
        }
        var seenModels = Set<String>()
        for c in main {
            // The CLI lists "opus" and the default both as Opus 5.5: one row.
            guard seenModels.insert(c.model).inserted else { continue }
            let isDefault = Self.matches(c, defaultId)
            let item = ActionMenuItem(c.title, checked: Self.matches(c, effective)) { setModel(isDefault ? nil : c.id) }
            item.image = isDefault ? NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Default") : NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
            if isDefault {
                item.subtitle = app.defaults.model != nil && thread == nil ? "The runner's default" : "The account's default"
            } else if let description = c.description {
                item.subtitle = description
            }
            menu.addItem(item)
        }
        if !older.isEmpty {
            let more = NSMenuItem(title: "Older models", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for c in older {
                sub.addItem(ActionMenuItem(c.title, checked: Self.matches(c, effective)) { setModel(c.id) })
            }
            more.submenu = sub
            menu.addItem(more)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Effort"))
        let chosen = effort
        let own = ActionMenuItem("Default", checked: chosen == nil) { setEffort(nil) }
        own.subtitle = thread?.effortInUse.map { "The model's own level, \(ComposerChips.effortTitle($0).lowercased()) last turn" } ?? "The model's own level"
        menu.addItem(own)
        let levels = effective.flatMap { ComposerChips.choice(for: $0, in: choices)?.effortLevels }.flatMap { $0.isEmpty ? nil : $0 } ?? ComposerChips.effortLevels
        for level in levels {
            menu.addItem(ActionMenuItem(ComposerChips.effortTitle(level), checked: chosen == level) { setEffort(level) })
        }
        return menu
    }

    private static func matches(_ c: ModelChoice, _ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return c.id == id || c.model == id
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

    private func setEffort(_ effort: String?) {
        if let thread { app.setEffort(thread.id, effort) } else { app.newThreadEffort = effort }
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
                    .font(.system(size: TypeScale.chip - 1))
                    .foregroundStyle(Color(nsColor: Theme.faintIcon))
                Text(title)
                    .font(.system(size: TypeScale.chip))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: Theme.faintIcon))
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
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

/// Opens a small menu: "Attach images…" and the folder.
private struct PlusButton: View {
    let menu: () -> NSMenu
    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .help("Attach images or change the folder")
        .accessibilityLabel("Attach images or change the folder")
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
        // Stop only while there's nothing typed: a follow-up typed during a
        // turn is sent (the runner queues it), so the one round button
        // never stops a turn Mike meant to add to. ⌘. and the Thread menu
        // still stop it.
        if running && !canSend {
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
            .help(running ? "Send (goes after this turn)" : "Send (Return)")
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
