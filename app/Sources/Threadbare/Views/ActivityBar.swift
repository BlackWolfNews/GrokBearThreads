import AppKit
import SwiftUI
import ThreadbareCore

/// The column of icons down the sidebar's left edge, like VS Code's activity
/// bar: the sidebar's views at the top (threads, hibernating, archive,
/// scheduled) and Usage and Settings at the foot. These were rows in a
/// footer under the threads, which took about five rows' height from the list.
struct ActivityBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    static var width: CGFloat { zoomed(44) }

    var body: some View {
        VStack(spacing: zoomed(4)) {
            ActivityButton(symbol: "bubble.left.and.bubble.right", title: "Threads", shortcut: "⌘1",
                           active: app.sidebarMode == .inbox) {
                app.sidebarMode = .inbox
            }
            ActivityButton(image: Bear.image(.sleep), title: "Hibernating", shortcut: "⌘2",
                           badge: app.snoozed.count, active: app.sidebarMode == .snoozed) {
                app.sidebarMode = .snoozed
            }
            // No badge: the archive only grows, so its count says nothing
            // needs looking at. The view's header has it.
            ActivityButton(symbol: "archivebox", title: "Archive", shortcut: "⌘3",
                           active: app.sidebarMode == .archive) {
                app.showArchive()
            }
            // Only once the runner has said it knows about schedules.
            if app.schedulesSupported {
                ActivityButton(symbol: "clock", title: "Scheduled", shortcut: "⌘4",
                               badge: app.activeScheduleCount, active: app.sidebarMode == .scheduled) {
                    app.showSchedules()
                }
            }
            Spacer(minLength: zoomed(8))
            UsageActivityButton()
            // The same window as ⌘, without a trip to the menu bar.
            ActivityButton(symbol: "gearshape", title: "Settings", shortcut: "⌘,", active: false) {
                openSettings()
            }
        }
        .padding(.top, zoomed(4))
        .padding(.bottom, zoomed(10))
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.separator).frame(width: 0.5).padding(.vertical, zoomed(4))
        }
    }
}

/// "Usage": every account's room and the CLIs' versions, in a popover.
private struct UsageActivityButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ActivityButton(symbol: "gauge.with.dots.needle.33percent", title: "Usage", active: app.usagePopoverShown) {
            app.usagePopoverShown.toggle()
        }
        // On the model, so a script can open it and `dump` can say so. To
        // the right of the icon, over the sidebar, as VS Code's account and
        // settings menus open beside its bar.
        .popover(isPresented: $app.usagePopoverShown, arrowEdge: .trailing) {
            UsagePopover().environment(app)
        }
    }
}

/// One icon in the bar: grey, primary with a faint square when it's the
/// view on show, and a small count in its corner when there is one.
private struct ActivityButton: View {
    var symbol: String? = nil
    /// Drawn instead of a symbol (the sleeping bear).
    var image: NSImage? = nil
    let title: String
    var shortcut: String? = nil
    var badge: Int? = nil
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(active || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: zoomed(32), height: zoomed(32))
                .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        // Grey, not accent: a count of things put away for
                        // later, not something that needs Mike.
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: zoomed(9), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, zoomed(3.5))
                            .frame(minWidth: zoomed(14), minHeight: zoomed(14))
                            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                            .offset(x: zoomed(3), y: -zoomed(2))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(badge.map { $0 > 0 ? "\($0)" : "" } ?? "")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder
    private var icon: some View {
        if let image {
            // The bear, tinted like the symbols.
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: zoomed(21), height: zoomed(21))
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: zoomed(15)))
        }
    }

    private var background: Color {
        if active { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return hovering ? SidebarMetrics.hover : .clear
    }
}
