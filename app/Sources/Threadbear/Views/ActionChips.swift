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
    /// The width the shelves have, and each piece's width, both from the
    /// last layout (`ActionChipsFit`).
    @State private var room: CGFloat?
    @State private var widths = ActionChipsFit.Widths()

    var body: some View {
        let actions = thread.actions
        let waiting = thread.patches.filter { $0.untrusted != nil }
        // As many chips as fit, in order, and the rest under "+N". A
        // scrolling row cut its last chip off mid-word. Worked out from
        // each chip's width rather than with a ViewThatFits of a row for
        // every count: that built every row it tried, about 65 chips for
        // 10 actions, each time the window asked the composer its size,
        // and froze the app for 15 seconds (5 Nov, THREADBEAR-Y).
        let shown = room.flatMap { ActionChipsFit.shown(thread: thread, waiting: waiting.isEmpty ? nil : waiting, widths: widths, room: $0) }
        let count = shown ?? 0
        ActionChipsRow(thread: thread, shown: Array(actions.prefix(count)), more: Array(actions.dropFirst(count)), waiting: waiting)
            // Until the chips are measured: there, a row tall, but not yet
            // showing a count it hasn't worked out.
            .opacity(shown == nil ? 0 : 1)
            .allowsHitTesting(shown != nil)
            // The width it's offered, never the row's: a row too wide for
            // it mustn't widen the room it was picked for (and the box).
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            .background(alignment: .topLeading) { measuring(actions, waiting: waiting) }
    }

    /// Each piece once, out of sight, for its width: every chip, the trust
    /// chip's shelf and the "+N" one, once for each number of digits N
    /// could have (its digits are all one width).
    private func measuring(_ actions: [Action], waiting: [PatchInfo]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(actions) { action in
                ActionChip(action: action, running: app.isRunning(action: action, in: thread.id)) {}
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.chips[action.id] = $0 }
            }
            if !waiting.isEmpty {
                ActionShelfTab { WaitingPatchesChip(waiting: waiting) {} }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.waiting = $0 }
            }
            ForEach(ActionChipsFit.moreCounts(actions.count), id: \.self) { count in
                ActionChipsMoreTab(threadId: thread.id, more: [], count: count)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.more[ActionChipsFit.digits(count)] = $0 }
            }
        }
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }
}

/// How many of a thread's action chips fit in a width, from each chip's
/// own width and the shelves' fixed parts, the ones ActionChipsRow lays
/// out with. `testTheRowWidthItWorksOutIsTheRowsWidth` keeps the two the
/// same.
enum ActionChipsFit {
    struct Widths: Equatable {
        var chips: [String: CGFloat] = [:]
        /// The trust chip on its shelf.
        var waiting: CGFloat?
        /// The "+N" shelf, by how many digits N has.
        var more: [Int: CGFloat] = [:]
    }

    static var rowSpacing: CGFloat { zoomed(6) }
    static var tabPadding: CGFloat { zoomed(6) }
    static var tabSpacing: CGFloat { zoomed(2) }
    static var badgeSize: CGFloat { zoomed(18) }
    static var badgePadding: CGFloat { zoomed(2) }
    static var hairlinePadding: CGFloat { zoomed(2) }
    static var badgeWidth: CGFloat { badgeSize + badgePadding * 2 }
    static var hairlineWidth: CGFloat { 1 + hairlinePadding * 2 }

    /// The row's width with the first `shown` actions on shelves and the
    /// rest under "+N"; nil until every piece it needs is measured.
    static func width(shown: Int, thread: ThreadSummary, waiting: [PatchInfo]?, widths: Widths) -> CGFloat? {
        let actions = thread.actions
        var parts: [CGFloat] = []
        if waiting != nil {
            guard let tab = widths.waiting else { return nil }
            parts.append(tab)
        }
        for shelf in ActionShelf.shelves(Array(actions.prefix(shown)), in: thread) {
            var items: [CGFloat] = [badgeWidth, hairlineWidth]
            for (index, group) in shelf.patches.enumerated() {
                if index > 0 { items.append(hairlineWidth) }
                for action in group {
                    guard let chip = widths.chips[action.id] else { return nil }
                    items.append(chip)
                }
            }
            parts.append(tabPadding * 2 + items.reduce(0, +) + tabSpacing * CGFloat(items.count - 1))
        }
        if shown < actions.count {
            guard let more = widths.more[digits(actions.count - shown)] else { return nil }
            parts.append(more)
        }
        return parts.reduce(0, +) + rowSpacing * CGFloat(max(parts.count - 1, 0))
    }

    static func digits(_ count: Int) -> Int { String(count).count }

    /// One count for each number of digits "+N" could have with `total`
    /// actions: 9 and 10 for 10 of them.
    static func moreCounts(_ total: Int) -> [Int] {
        guard total > 0 else { return [] }
        return (1...digits(total)).map { min(Int(pow(10, Double($0))) - 1, total) }
    }

    /// The most chips that fit in `room`, or none when not even one does,
    /// as a ViewThatFits of a row for each count would pick.
    static func shown(thread: ThreadSummary, waiting: [PatchInfo]?, widths: Widths, room: CGFloat) -> Int? {
        for shown in stride(from: thread.actions.count, through: 0, by: -1) {
            guard let width = width(shown: shown, thread: thread, waiting: waiting, widths: widths) else { return nil }
            // Half a point for rounding: each piece lands on a whole point.
            if width <= room + 0.5 { return shown }
        }
        return 0
    }
}

/// The shelves with `shown` on them and `more` under "+N".
struct ActionChipsRow: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let shown: [Action]
    let more: [Action]
    let waiting: [PatchInfo]

    var body: some View {
        HStack(alignment: .bottom, spacing: ActionChipsFit.rowSpacing) {
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
                ActionChipsMoreTab(threadId: thread.id, more: more, count: more.count)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.cardBorder))
            .frame(width: 1, height: zoomed(14))
            .padding(.horizontal, ActionChipsFit.hairlinePadding)
    }
}

/// "+N" on a shelf of its own: the chips that didn't fit, in a menu.
struct ActionChipsMoreTab: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let more: [Action]
    let count: Int

    var body: some View {
        ActionShelfTab {
            IconMenu {
                ForEach(more) { action in
                    Button(action.title, systemImage: "bolt") { app.runAction(action, in: threadId) }
                        .disabled(app.isRunning(action: action, in: threadId))
                }
            } label: {
                // Even digits, so every count with as many digits is as
                // wide, which is how ActionChipsFit measures it.
                Text("+\(count)")
                    .font(.system(size: TypeScale.chip).monospacedDigit())
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

/// One shelf: a tab with rounded top corners whose bottom edge sits on
/// the composer's top edge, a shade quieter than the box itself.
private struct ActionShelfTab<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: zoomed(10), topTrailingRadius: zoomed(10), style: .continuous)
        HStack(spacing: ActionChipsFit.tabSpacing) { content }
            .padding(.horizontal, ActionChipsFit.tabPadding)
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
        .frame(width: ActionChipsFit.badgeSize, height: ActionChipsFit.badgeSize)
        .padding(.horizontal, ActionChipsFit.badgePadding)
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

struct ActionChip: View {
    let action: Action
    let running: Bool
    let run: () -> Void
    @State private var hovered = false

    #if DEBUG
    /// How many times a chip's been built, for tests.
    nonisolated(unsafe) static var bodyCount = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyCount += 1
        #endif
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
