import AppKit
import SwiftUI
import ThreadbearCore

/// Thread ids in replies drawn as chips. The renderer marks id-shaped
/// words (`.tbThreadRef`); this says which of them name a thread, from the
/// thread list. Main thread only: it's read while drawing.
enum ThreadChips {
    nonisolated(unsafe) private static var index = ThreadRefs.Index([])
    /// Posted when the thread list gains or loses a thread, so text already
    /// on screen can draw a new thread's id as a chip.
    static let changed = Notification.Name("ThreadChips.changed")

    static func update(_ threadIds: some Sequence<String>) {
        index = ThreadRefs.Index(threadIds)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The thread `word` names, if any.
    static func resolve(_ word: String) -> String? { index.resolve(word) }

    /// The chips in `storage`: each one's range and thread id.
    static func chips(in storage: NSAttributedString) -> [(range: NSRange, threadId: String)] {
        var found: [(NSRange, String)] = []
        storage.enumerateAttribute(.tbThreadRef, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let word = value as? String, let id = resolve(word) { found.append((range, id)) }
        }
        return found
    }
}

/// What a chip's hover card says: the thread's title, then where it is
/// and what it's doing.
struct ThreadChipCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(3)) {
            Text(title)
                .font(.system(size: TypeScale.label, weight: .semibold))
                .lineLimit(2)
            Text(detail)
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Click to open")
                .font(.system(size: TypeScale.small))
                .foregroundStyle(.tertiary)
                .padding(.top, zoomed(3))
        }
        .padding(.horizontal, zoomed(12))
        .padding(.vertical, zoomed(10))
        .frame(width: zoomed(300), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The card for a thread, or nil if it's gone.
    @MainActor static func make(threadId: String) -> ThreadChipCard? {
        let app = AppModel.shared
        guard let thread = app.threads[threadId] else { return nil }
        let title = thread.title.isEmpty ? "Untitled thread" : thread.title
        let account = thread.accountId.isEmpty ? nil : AccountName.short(thread.accountId, accounts: app.accounts)
        return ThreadChipCard(title: title, detail: ThreadRefs.detail(thread, account: account, now: Date()))
    }
}

/// The hover card of a chip or a link (LinkPeek): a small borderless
/// window under it, like a tooltip. NSPopover's glass corners (about 20 pt on macOS 26) and arrow
/// looked heavy for a few lines of text, and it can't be made squarer.
final class ChipCardWindow: NSPanel {
    static let radius: CGFloat = 8
    static let gap: CGFloat = 4

    static func show(_ card: some View, below chip: NSRect, parent: NSWindow) -> ChipCardWindow {
        let host = NSHostingView(rootView: card)
        let size = host.fittingSize
        let window = ChipCardWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Hover only: clicks go to the chip under it.
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = parent.effectiveAppearance

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = radius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = Theme.cardBorder.resolvedCGColor(for: parent.effectiveAppearance)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        window.contentView = background

        // Under the chip, its left edge lined up with the chip's; above it
        // when there's no room below, and kept on the screen.
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: chip.minX, y: chip.minY - gap - size.height)
        if origin.y < screen.minY { origin.y = chip.maxY + gap }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        window.setFrameOrigin(origin)
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
        return window
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

private extension NSColor {
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}
