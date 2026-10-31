import AppKit
import SwiftUI

/// An NSMenu drawn in a popover, for when macOS won't show the menu itself.
/// On macOS 27.2 a window left on the drag Space by a drag has every menu
/// opened from it made and placed but never shown (DragSpace; MenuWatch
/// spots it). Popovers still show then, so the same menu is drawn here
/// instead: titles, icons, ticks, subtitles, section headers, separators,
/// and submenus opened in place. A pick runs the item through the menu
/// itself (`performActionForItem`), so it does exactly what choosing it
/// from the menu would.
@MainActor
enum MenuPopover {
    private static var shown: NSPopover?
    private static var closing: CloseWatch?
    /// The rows on show, for the automation's `click`.
    private(set) static var rows: [MenuPopoverRow] = []

    static var isShown: Bool { shown?.isShown == true }

    /// `onClose` runs once it's gone, however it goes.
    static func show(_ menu: NSMenu, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge, onClose: (() -> Void)? = nil) {
        close()
        let rows = MenuPopoverRow.rows(of: menu)
        AppLog.write("menu", "as a popover: \(rows.count) rows, in \(view.window.map { "window \($0.windowNumber)" } ?? "no window")")
        guard !rows.isEmpty else { onClose?(); return }
        self.rows = rows
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: MenuPopoverView(rows: rows) { row in pick(row) })
        popover.contentViewController = controller
        // Measured first, as the composer's pickers are, so it's placed for
        // its real size.
        popover.contentSize = controller.view.fittingSize
        // Shown from the window's content view, at the same place, rather
        // than from `view`: a sidebar row's moon is only there while the row
        // is hovered, and as the pointer went down into the popover the row
        // let the moon go and its view was freed, which closes a popover
        // shown from it (Mike, 1 Nov). The edge is turned round when the
        // content view's y runs the other way.
        let host = view.window?.contentView ?? view
        var hostEdge = edge
        if host !== view, host.isFlipped != view.isFlipped {
            if edge == .minY { hostEdge = .maxY } else if edge == .maxY { hostEdge = .minY }
        }
        let watch = CloseWatch(onClose)
        popover.delegate = watch
        closing = watch
        popover.show(relativeTo: view.convert(rect, to: host), of: host, preferredEdge: hostEdge)
        shown = popover
    }

    /// At the pointer, in the window under it: a right-click menu's place.
    /// With the pointer off the app's windows (a menu opened from the
    /// keyboard, or a scripted run), the middle of the front window.
    static func showAtPointer(_ menu: NSMenu) {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        if let window = NSApp.windows.first(where: { $0.windowNumber == number && $0.contentView != nil }), let view = window.contentView {
            let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
            show(menu, relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, edge: .maxX)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? MainWindowFrame.window,
                  let view = window.contentView {
            show(menu, relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, edge: .maxY)
        } else {
            AppLog.write("menu", "no window to show the popover in")
        }
    }

    static func close() {
        shown?.close()
        shown = nil
        closing?.fire()
        closing = nil
    }

    static func pick(_ row: MenuPopoverRow) {
        guard row.enabled, let perform = row.perform else { return }
        close()
        // After the popover's gone, as a menu is gone before its action
        // runs: some actions put up an alert or a sheet.
        DispatchQueue.main.async { perform() }
    }
}

/// Runs a closure once when its popover closes, by a pick, a click outside
/// or Esc.
@MainActor
private final class CloseWatch: NSObject, NSPopoverDelegate {
    private var action: (() -> Void)?

    init(_ action: (() -> Void)?) { self.action = action }

    func fire() {
        let action = self.action
        self.action = nil
        action?()
    }

    func popoverDidClose(_ notification: Notification) { fire() }
}

/// One line of a menu: an item, a section header or a separator.
struct MenuPopoverRow: Identifiable {
    enum Kind { case item, header, separator }
    let id: Int
    let kind: Kind
    let title: String
    var subtitle: String?
    var image: NSImage?
    var checked = false
    var enabled = true
    var indent = 0
    var perform: (() -> Void)?
    var children: [MenuPopoverRow] = []

    /// The menu's visible items, validated first so disabled ones show as
    /// disabled, with each submenu's items as children.
    @MainActor
    static func rows(of menu: NSMenu, ids: inout Int, indent: Int = 0) -> [MenuPopoverRow] {
        menu.update()
        var result: [MenuPopoverRow] = []
        for (index, item) in menu.items.enumerated() where !item.isHidden {
            ids += 1
            if item.isSeparatorItem {
                // Never two in a row, or one at the top.
                if let last = result.last, last.kind != .separator { result.append(MenuPopoverRow(id: ids, kind: .separator, title: "")) }
                continue
            }
            if item.isSectionHeader {
                result.append(MenuPopoverRow(id: ids, kind: .header, title: item.title, indent: indent))
                continue
            }
            var row = MenuPopoverRow(id: ids, kind: .item, title: item.title, subtitle: item.subtitle, image: item.image,
                                     checked: item.state == .on, enabled: item.isEnabled, indent: indent + item.indentationLevel)
            if let submenu = item.submenu {
                row.children = rows(of: submenu, ids: &ids, indent: 0)
            } else if item.action != nil {
                // Holds the menu: nothing else does once it has been handed over.
                row.perform = { menu.performActionForItem(at: index) }
            } else {
                row.enabled = false
            }
            result.append(row)
        }
        if result.last?.kind == .separator { result.removeLast() }
        return result
    }

    @MainActor
    static func rows(of menu: NSMenu) -> [MenuPopoverRow] {
        var ids = 0
        return rows(of: menu, ids: &ids)
    }
}

private struct MenuPopoverView: View {
    let rows: [MenuPopoverRow]
    let pick: (MenuPopoverRow) -> Void
    /// Submenus opened in place.
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            list(rows)
        }
        .padding(zoomed(5))
        .frame(minWidth: zoomed(170), maxWidth: zoomed(380), alignment: .leading)
        .fixedSize()
    }

    private func list(_ rows: [MenuPopoverRow]) -> AnyView {
        AnyView(ForEach(rows) { row in
            switch row.kind {
            case .separator:
                Divider().padding(.vertical, zoomed(4)).padding(.horizontal, zoomed(8))
            case .header:
                Text(row.title)
                    .font(.system(size: TypeScale.chip - 1, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, zoomed(8))
                    .padding(.top, zoomed(4))
                    .padding(.bottom, zoomed(2))
            case .item:
                MenuPopoverItem(row: row, expanded: open.contains(row.id)) {
                    if row.children.isEmpty {
                        pick(row)
                    } else if open.contains(row.id) {
                        open.remove(row.id)
                    } else {
                        open.insert(row.id)
                    }
                }
                if open.contains(row.id) {
                    list(row.children).padding(.leading, zoomed(14))
                }
            }
        })
    }
}

private struct MenuPopoverItem: View {
    let row: MenuPopoverRow
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: zoomed(7)) {
                // A tick column, as a menu has, so titles line up.
                Image(systemName: "checkmark")
                    .font(.system(size: zoomed(10), weight: .semibold))
                    .opacity(row.checked ? 1 : 0)
                    .frame(width: zoomed(10))
                if let image = row.image {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                        .frame(width: zoomed(16))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).font(.system(size: TypeScale.chip)).lineLimit(1)
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: TypeScale.chip - 2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: zoomed(12))
                if !row.children.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: zoomed(9), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, zoomed(4) + CGFloat(row.indent) * zoomed(12))
            .padding(.trailing, zoomed(8))
            .padding(.vertical, zoomed(4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: zoomed(5)).fill(Color.primary.opacity(hovering && row.enabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .opacity(row.enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .tip(row.title)
    }
}
