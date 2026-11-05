import AppKit
import SwiftUI
import ThreadbearCore

/// The thread's actions (from its folder's patches) as shelves on top of
/// the composer: tabs on its top edge, one for each place the chips came
/// from, led by the badge the rail's panel buttons wear (the project's
/// icon, a folder, a house, a wrench, a box). Inside the box they looked
/// like part of writing a message (Mike, 30 Oct); on a shelf of their
/// own they read as the project's buttons. A command action runs in the
/// folder and its output lands in the transcript; a prompt action sends
/// its message. Chips from one patch sit together, with a hairline
/// between patches on the same shelf.
struct ActionChips: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        let actions = thread.actions
        // As many chips as fit, in order, and the rest under "+N": the
        // first of these that fits the box's width is the one shown. A
        // scrolling row cut its last chip off mid-word.
        ViewThatFits(in: .horizontal) {
            ForEach((0...actions.count).reversed(), id: \.self) { shown in
                row(Array(actions.prefix(shown)), more: Array(actions.dropFirst(shown)))
            }
        }
    }

    private func row(_ shown: [Action], more: [Action]) -> some View {
        HStack(alignment: .bottom, spacing: zoomed(6)) {
            let waiting = thread.patches.filter { $0.untrusted != nil }
            if !waiting.isEmpty {
                ActionShelfTab {
                    WaitingPatchesChip(waiting: waiting) { app.showPane(.patches) }
                }
            }
            ForEach(Array(ActionShelf.shelves(shown, in: thread).enumerated()), id: \.offset) { _, shelf in
                ActionShelfTab {
                    ShelfBadge(origin: shelf.origin, thread: thread)
                    hairline
                    ForEach(Array(shelf.patches.enumerated()), id: \.offset) { index, group in
                        if index > 0 { hairline }
                        ForEach(group) { action in
                            ActionChip(action: action, running: app.isRunning(action: action, in: thread.id)) {
                                app.runAction(action, in: thread.id)
                            }
                        }
                    }
                }
            }
            if !more.isEmpty {
                ActionShelfTab {
                    IconMenu {
                        ForEach(more) { action in
                            Button(action.title, systemImage: "bolt") { app.runAction(action, in: thread.id) }
                                .disabled(app.isRunning(action: action, in: thread.id))
                        }
                    } label: {
                        Text("+\(more.count)")
                            .font(.system(size: TypeScale.chip))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, zoomed(6))
                            .padding(.vertical, zoomed(4))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .tip(more.map(\.title).joined(separator: ", "))
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.cardBorder))
            .frame(width: 1, height: zoomed(14))
            .padding(.horizontal, zoomed(2))
    }
}

/// One shelf: a tab with rounded top corners whose bottom edge sits on
/// the composer's top edge, a shade quieter than the box itself.
private struct ActionShelfTab<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: zoomed(10), topTrailingRadius: zoomed(10), style: .continuous)
        HStack(spacing: zoomed(2)) { content }
            .padding(.horizontal, zoomed(6))
            .padding(.vertical, zoomed(4))
            .background(shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// Where a shelf's chips came from, at its left: the project's own icon,
/// or the rail's glyph for the rest, with the same words on hover.
private struct ShelfBadge: View {
    @Environment(AppModel.self) private var app
    let origin: PanelOrigin
    let thread: ThreadSummary

    var body: some View {
        let title = PanelOriginBadge.projectTitle(origin, thread: thread, app: app)
        Group {
            if case .project(let id) = origin {
                ProjectIconView(project: app.project(id), title: title ?? "", size: 14)
            } else if let symbol = origin.symbol {
                Image(systemName: symbol)
                    .font(.system(size: zoomed(10), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: zoomed(18), height: zoomed(18))
        .padding(.horizontal, zoomed(2))
        .contentShape(Rectangle())
        .tip(origin.tip("These buttons", projectTitle: title))
    }
}

/// Patch files in the thread's folder that haven't run because they
/// aren't trusted yet. Opens Patches, where each can be read and trusted.
struct WaitingPatchesChip: View {
    let waiting: [PatchInfo]
    let open: () -> Void

    /// "1 patch to trust", or the folder's Claude Code hooks when they're
    /// what waits.
    static func label(_ waiting: [PatchInfo]) -> String {
        let claude = waiting.contains { $0.source == "claude" }
        let patches = waiting.count - (claude ? 1 : 0)
        if patches == 0 { return "Hooks to trust" }
        if claude { return "\(waiting.count) to trust" }
        return patches == 1 ? "1 patch to trust" : "\(patches) patches to trust"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: zoomed(5)) {
                Image(systemName: "lock.shield")
                    .font(.system(size: zoomed(11), weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.needsYou))
                Text(Self.label(waiting))
                    .foregroundStyle(.primary)
            }
            .font(.system(size: TypeScale.chip))
            .padding(.horizontal, zoomed(8))
            .padding(.vertical, zoomed(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(waiting.contains { $0.source == "claude" }
             ? "This folder has Claude Code hooks, environment settings or patch files that haven't been used, because you haven't trusted them yet. Each can run code on your Mac or change where Claude sends your messages. Open Patches to read and trust them."
             : "This folder has patch files that haven't run, because you haven't trusted them yet. A patch is code that runs on your Mac. Open Patches to read and trust them.")
    }
}

private struct ActionChip: View {
    let action: Action
    let running: Bool
    let run: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: zoomed(5)) {
                if running {
                    SpinnerMark(color: .secondaryLabelColor).frame(width: zoomed(11), height: zoomed(11))
                } else {
                    // The patch's own icon when it has one (which project or
                    // tool it's for); else the patch glyph for a command, a
                    // bubble for a message, an arrow out for a page.
                    if let image = PatchImage.image(action.iconFile) {
                        // The tool's own icon, in colour.
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: zoomed(13), height: zoomed(13))
                    } else {
                        Image(systemName: action.icon ?? Self.glyph(for: action.kind))
                            .font(.system(size: zoomed(11), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(action.title)
                    .foregroundStyle(.primary)
                // The patch's live count: comments waiting, say.
                if let badge = action.badge {
                    Text(badge > 99 ? "99+" : String(badge))
                        .font(.system(size: TypeScale.small, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, zoomed(5))
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .font(.system(size: TypeScale.chip))
            .padding(.horizontal, zoomed(8))
            .padding(.vertical, zoomed(4))
            // The shelf is the chips' frame, so each is just a fill under
            // the pointer rather than a capsule of its own.
            .background(RoundedRectangle(cornerRadius: zoomed(6), style: .continuous).fill(Color.primary.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(running)
        .tip(Self.tip(for: action))
    }

    /// What it does, then where it's from: "From the checks patch, in
    /// threadbear", so a chip's origin is a hover away.
    static func glyph(for kind: Action.Kind) -> String {
        switch kind {
        case .prompt: return "text.bubble"
        case .url: return "arrow.up.right.square"
        case .command: return "square.dashed"
        }
    }

    static func tip(for action: Action) -> String {
        let what = action.note ?? action.command ?? action.prompt ?? action.url ?? action.title
        guard !action.patch.isEmpty else { return what }
        let folder = action.folder.map { ", in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        return "\(what)\nFrom the \(action.patch) patch\(folder)"
    }
}
