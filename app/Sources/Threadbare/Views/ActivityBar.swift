import AppKit
import SwiftUI
import ThreadbareCore

/// The column of icons down the sidebar's left edge, like VS Code's activity
/// bar: the sidebar's views at the top (threads, hibernating, archive,
/// scheduled, projects, the librarian) and Usage and Settings at the foot. These were rows in a
/// footer under the threads, which took about five rows' height from the list.
struct ActivityBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    /// The highlight behind the view on show slides between icons in this.
    @Namespace private var activeSpace
    static var width: CGFloat { zoomed(44) }

    var body: some View {
        VStack(spacing: zoomed(4)) {
            ActivityButton(symbol: "bubble.left.and.bubble.right", title: "Threads", shortcut: "⌘1",
                           active: app.sidebarMode == .inbox, slides: true) {
                app.sidebarMode = .inbox
            }
            ActivityButton(image: Bear.image(.sleep), title: "Hibernating", shortcut: "⌘2",
                           badge: app.snoozed.count, active: app.sidebarMode == .snoozed, slides: true) {
                app.sidebarMode = .snoozed
            }
            // No badge: the archive only grows, so its count says nothing
            // needs looking at. The view's header has it.
            ActivityButton(symbol: "archivebox", title: "Archive", shortcut: "⌘3",
                           active: app.sidebarMode == .archive, slides: true) {
                app.showArchive()
            }
            // Only once the runner has said it knows about schedules.
            if app.schedulesSupported {
                ActivityButton(symbol: "clock", title: "Scheduled", shortcut: "⌘4",
                               badge: app.activeScheduleCount, active: app.sidebarMode == .scheduled, slides: true) {
                    app.showSchedules()
                }
            }
            // Only once the runner has said it knows about projects.
            if app.projectsSupported {
                ActivityButton(symbol: "square.stack.3d.up", title: "Projects", shortcut: "⌘5",
                               active: app.sidebarMode == .projects, slides: true) {
                    app.showProjects()
                }
                // A count while it's looking at a thread or has some
                // waiting: what it's doing and about to do.
                ActivityButton(symbol: "books.vertical", title: "Librarian", shortcut: "⌘6",
                               badge: app.librarian?.pendingCount, active: app.sidebarMode == .librarian, slides: true) {
                    app.showLibrarian()
                }
            }
            Spacer(minLength: zoomed(8))
            // Only while the app or the runner has an update on its way.
            UpdatesActivityButton()
            UsageActivityButton()
            // The same window as ⌘, without a trip to the menu bar.
            ActivityButton(symbol: "gearshape", title: "Settings", shortcut: "⌘,", active: false) {
                openSettings()
            }
        }
        .environment(\.sidebarRowSpace, activeSpace)
        .animation(Juice.selection, value: app.sidebarMode)
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
/// view on show, and a small count in its corner when there is one, or a
/// dot when something there needs Mike.
struct ActivityButton: View {
    var symbol: String? = nil
    /// Drawn instead of a symbol (the sleeping bear).
    var image: NSImage? = nil
    let title: String
    var shortcut: String? = nil
    var badge: Int? = nil
    /// Accent, unlike the counts: it means something needs Mike.
    var dot: Bool = false
    /// The same dot in grey, when `dot` isn't set: something's going on
    /// that sorts itself out, like an update on its way.
    var quietDot: Bool = false
    let active: Bool
    /// One of the sidebar's views: the highlight slides between these.
    /// Usage and Settings open over the view, so theirs just shows.
    var slides = false
    let action: () -> Void
    @State private var hovering = false
    /// Counts clicks, to give the icon a little bounce on each.
    @State private var taps = 0
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sidebarRowSpace) private var activeSpace

    var body: some View {
        Button {
            if !Juice.reduceMotion { taps += 1 }
            action()
        } label: {
            icon
                .foregroundStyle(active || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // Pressed in a touch, then back with a small overshoot.
                .keyframeAnimator(initialValue: 1.0, trigger: taps) { icon, scale in
                    icon.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(0.82, duration: 0.08)
                        SpringKeyframe(1, duration: 0.35, spring: .bouncy(duration: 0.35, extraBounce: 0.25))
                    }
                }
                .frame(width: zoomed(32), height: zoomed(32))
                .background {
                    ZStack {
                        if hovering && !active {
                            RoundedRectangle(cornerRadius: SidebarMetrics.corner).fill(SidebarMetrics.hover)
                                .transition(.opacity)
                        }
                        // Slides to whichever view is on show.
                        if active {
                            RoundedRectangle(cornerRadius: SidebarMetrics.corner)
                                .fill(Color.primary.opacity(activeState == .key ? 0.08 : 0.06))
                                .matched("active", in: slides ? activeSpace : nil)
                        }
                    }
                    .animation(Juice.hover, value: hovering)
                }
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        // Grey, not accent: a count of things put away for
                        // later, not something that needs Mike.
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: zoomed(9), weight: .semibold))
                            .monospacedDigit()
                            // The number rolls when it changes.
                            .contentTransition(.numericText(value: Double(badge)))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, zoomed(3.5))
                            .frame(minWidth: zoomed(14), minHeight: zoomed(14))
                            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                            .offset(x: zoomed(3), y: -zoomed(2))
                            .allowsHitTesting(false)
                            .transition(Juice.popIn)
                    } else if dot || quietDot {
                        Circle()
                            .fill(dot ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: zoomed(7), height: zoomed(7))
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: zoomed(1), y: zoomed(1))
                            .allowsHitTesting(false)
                            .transition(Juice.popIn)
                    }
                }
                .animation(Juice.pop, value: badge ?? 0)
                .animation(Juice.pop, value: dot || quietDot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shortcutHint(shortcut, .after)
        .onHover { hovering = $0 }
        .tip(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(dot ? "Needs you" : badge.map { $0 > 0 ? "\($0)" : "" } ?? "")
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
}
