import AppKit
import SwiftUI
import ThreadbearCore

/// The little bar above words selected in a message: Explain (opens the
/// pane, ExplainModel.swift), Quote (into the composer) and Copy. A
/// borderless child window like ChipCardWindow, but one that takes clicks.
/// It never becomes key, so clicking it leaves the selection where it is.
final class SelectionBarWindow: NSPanel {
    static let gap: CGFloat = 6

    enum Action { case explain, quote, copy }

    static func show(above selection: NSRect, within column: NSRect, parent: NSWindow, act: @escaping (Action) -> Void) -> SelectionBarWindow {
        let host = NSHostingView(rootView: SelectionBar(act: act).environment(AppModel.shared))
        let size = host.fittingSize
        let window = SelectionBarWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.appearance = parent.effectiveAppearance

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = ChipCardWindow.radius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        parent.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.borderColor = Theme.cardBorder.cgColor
        }
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        window.contentView = background

        // Above the selection's first line, starting where it starts; below
        // its last line when there's no room above (the top of the window).
        // Kept inside the transcript's column, not over the pane beside it.
        let content = parent.contentLayoutRect.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY)
        let limits = column.isEmpty ? content : column.intersection(content)
        var origin = NSPoint(x: selection.minX, y: selection.maxY + gap)
        if origin.y + size.height > limits.maxY { origin.y = selection.minY - gap - size.height }
        origin.x = max(min(origin.x, limits.maxX - size.width - 4), limits.minX + 4)
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

private struct SelectionBar: View {
    let act: (SelectionBarWindow.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item("Explain", symbol: "sparkle.magnifyingglass", tip: "Explain this beside the thread, without adding to it", .explain)
            divider
            item("Quote", symbol: "text.quote", tip: "Quote this in your reply", .quote)
            divider
            item("Copy", symbol: "doc.on.doc", tip: "Copy", .copy)
        }
        .padding(.horizontal, zoomed(3))
        .padding(.vertical, zoomed(3))
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 0.5, height: zoomed(14))
    }

    private func item(_ title: String, symbol: String, tip: String, _ action: SelectionBarWindow.Action) -> some View {
        SelectionBarButton(title: title, symbol: symbol) { act(action) }
            .tip(tip)
    }
}

private struct SelectionBarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: TypeScale.detail, weight: .medium))
                .padding(.horizontal, zoomed(8))
                .padding(.vertical, zoomed(4))
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
