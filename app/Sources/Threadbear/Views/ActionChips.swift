import AppKit
import SwiftUI
import ThreadbearCore

/// The thread's actions (from its folder's patches) as chips above the
/// composer's text. A command action runs in the folder and its output
/// lands in the transcript; a prompt action sends its message. Chips from
/// one patch sit together, with a hairline between patches, so a row that
/// mixes a repo's checks with a tool's chips (Tandem's, say) reads as two.
struct ActionChips: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: zoomed(6)) {
                let waiting = thread.patches.filter { $0.untrusted != nil }.count
                if waiting > 0 {
                    WaitingPatchesChip(count: waiting) { app.showPane(.patches) }
                }
                ForEach(Array(Self.groups(thread.actions).enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: Theme.cardBorder))
                            .frame(width: 1, height: zoomed(14))
                            .padding(.horizontal, zoomed(2))
                    }
                    ForEach(group) { action in
                        ActionChip(action: action, running: app.isRunning(action: action, in: thread.id)) {
                            app.runAction(action, in: thread.id)
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// The actions by patch, each patch where its first chip was.
    static func groups(_ actions: [Action]) -> [[Action]] {
        var order: [String] = []
        var byPatch: [String: [Action]] = [:]
        for action in actions {
            if byPatch[action.patch] == nil { order.append(action.patch) }
            byPatch[action.patch, default: []].append(action)
        }
        return order.map { byPatch[$0]! }
    }
}

/// Patch files in the thread's folder that haven't run because they
/// aren't trusted yet. Opens Patches, where each can be read and trusted.
private struct WaitingPatchesChip: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: zoomed(5)) {
                Image(systemName: "lock.shield")
                    .font(.system(size: zoomed(11), weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.needsYou))
                Text(count == 1 ? "1 patch to trust" : "\(count) patches to trust")
                    .foregroundStyle(.primary)
            }
            .font(.system(size: TypeScale.chip))
            .padding(.horizontal, zoomed(9))
            .padding(.vertical, zoomed(4))
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip("This folder has patch files that haven't run, because you haven't trusted them yet. A patch is code that runs on your Mac. Open Patches to read and trust them.")
    }
}

private struct ActionChip: View {
    let action: Action
    let running: Bool
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: zoomed(5)) {
                if running {
                    SpinnerMark(color: .secondaryLabelColor).frame(width: zoomed(11), height: zoomed(11))
                } else {
                    // The patch's own icon when it has one (which project or
                    // tool it's for); else the patch glyph for a command, a
                    // bubble for a message.
                    if let image = PatchImage.image(action.iconFile) {
                        // The tool's own icon, in colour.
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: zoomed(13), height: zoomed(13))
                    } else {
                        Image(systemName: action.icon ?? (action.kind == .prompt ? "text.bubble" : "square.dashed"))
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
            .padding(.horizontal, zoomed(9))
            .padding(.vertical, zoomed(4))
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .tip(Self.tip(for: action))
    }

    /// What it does, then where it's from: "From the checks patch, in
    /// threadbear", so a chip's origin is a hover away.
    static func tip(for action: Action) -> String {
        let what = action.note ?? action.command ?? action.prompt ?? action.title
        guard !action.patch.isEmpty else { return what }
        let folder = action.folder.map { ", in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        return "\(what)\nFrom the \(action.patch) patch\(folder)"
    }
}
