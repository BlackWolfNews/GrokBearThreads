import AppKit
import SwiftUI

/// What the app gives the dock for each panel.
public struct DockContent {
    public var title: (PanelID) -> String
    public var symbol: (PanelID) -> String?
    public var view: (PanelID) -> AnyView
    /// Drawn in place of the title when the panel is on its own (the
    /// thread's name and folder over the transcript, say). Nil: the title.
    public var header: (PanelID) -> AnyView?
    /// Buttons at the end of the panel's bar while it's showing.
    public var accessory: (PanelID) -> AnyView?
    /// False for a panel the app always keeps (the transcript): no ×, no Close.
    public var closable: (PanelID) -> Bool
    /// False for a panel with nothing to show right now (the selected
    /// thread has no such panel): its tab is left out and another of its
    /// group's shows, without changing the layout, so it's back when it
    /// has something again.
    public var available: (PanelID) -> Bool

    public init(
        title: @escaping (PanelID) -> String,
        symbol: @escaping (PanelID) -> String? = { _ in nil },
        header: @escaping (PanelID) -> AnyView? = { _ in nil },
        accessory: @escaping (PanelID) -> AnyView? = { _ in nil },
        closable: @escaping (PanelID) -> Bool = { _ in true },
        available: @escaping (PanelID) -> Bool = { _ in true },
        view: @escaping (PanelID) -> AnyView
    ) {
        self.available = available
        self.title = title
        self.symbol = symbol
        self.header = header
        self.accessory = accessory
        self.closable = closable
        self.view = view
    }
}

/// How the dock fits the app around it.
public struct DockOptions {
    public var headerHeight: CGFloat = 32
    public var titleSize: CGFloat = 12
    /// In a window without a title bar: room left at the start of the
    /// top-left panel's bar for the traffic lights. 0 with a title bar.
    public var trafficLights: CGFloat = 0
    /// In a window without a title bar: the strip beside the traffic lights
    /// moves the window, as a title bar would. Only that strip: Mike reached
    /// for a panel's bar to move the panel and got the window (28 Oct), so
    /// every other bar moves its panel, empty part and all.
    public var cornerMovesWindow = false
    /// The app's tooltips, for an app whose `.help` doesn't show.
    public var tip: @MainActor (AnyView, String) -> AnyView = { view, text in AnyView(view.help(text)) }
    /// Wraps a panel in a window of its own, to give it what the app's
    /// main window gives its views (its model in the environment, say),
    /// as a new window doesn't inherit any of that.
    public var windowContent: @MainActor (AnyView) -> AnyView = { $0 }
    /// Called on a panel's window of its own as it's made, before it shows.
    public var prepareWindow: @MainActor (NSWindow) -> Void = { _ in }

    public init() {}
}

enum DockSpace {
    static let name = "BearDock"
}

/// System colours, so the dock follows light and dark like the app around it.
enum DockTheme {
    static let panel = Color(nsColor: .windowBackgroundColor)
    /// Shows through the 1 pt gaps between panels, as the hairlines.
    static let hairline = Color(nsColor: .separatorColor)
    static let headerText = Color.primary
    static let secondary = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor
    static let gap: CGFloat = 1
}

/// The whole docking area: the layout's tree of splits and groups, with the
/// drag's ghost, drop preview and compass drawn over it.
public struct DockView: View {
    let controller: DockController
    let content: DockContent
    let options: DockOptions
    @Namespace private var space

    public init(controller: DockController, options: DockOptions = DockOptions(), content: DockContent) {
        self.controller = controller
        self.options = options
        self.content = content
    }

    public init<C: View>(
        controller: DockController,
        options: DockOptions = DockOptions(),
        title: @escaping (PanelID) -> String,
        symbol: @escaping (PanelID) -> String? = { _ in nil },
        @ViewBuilder content: @escaping (PanelID) -> C
    ) {
        self.init(controller: controller, options: options, content: DockContent(title: title, symbol: symbol, view: { AnyView(content($0)) }))
    }

    public var body: some View {
        NodeView(node: controller.layout.root)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DockTheme.hairline)
            .background(DockTheme.panel)
            .overlay(alignment: .topLeading) {
                DragOverlay()
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(DockSpace.name))
            .onGeometryChange(for: CGRect.self) { CGRect(origin: .zero, size: $0.size) } action: { controller.bounds = $0 }
            .background(DockAnchor(controller: controller))
            // Panels in windows of their own: opened (again, at launch),
            // moved and closed as the layout says.
            .onAppear { syncWindows() }
            .onChange(of: controller.layout.floating) { syncWindows() }
            .environment(controller)
            .environment(\.dockContent, content)
            .environment(\.dockOptions, options)
            .environment(\.dockNamespace, space)
    }

    private func syncWindows() {
        controller.windows.content = content
        controller.windows.options = options
        controller.windows.sync()
    }
}

extension EnvironmentValues {
    @Entry var dockContent = DockContent(title: { $0 }, view: { _ in AnyView(EmptyView()) })
    @Entry var dockOptions = DockOptions()
    @Entry var dockNamespace: Namespace.ID?
}

extension View {
    @MainActor func dockTip(_ text: String, _ options: DockOptions) -> AnyView {
        options.tip(AnyView(self), text)
    }
}

/// A split or a group. AnyView is where the tree recurses.
struct NodeView: View {
    let node: DockNode

    var body: some View {
        switch node {
        case .group(let g): AnyView(GroupView(group: g))
        case .split(let s): AnyView(SplitView(split: s))
        }
    }
}

// MARK: Splits

struct SplitView: View {
    let split: DockSplit
    @Environment(DockController.self) private var controller
    /// The fractions when a divider drag started.
    @State private var startFractions: [Double]?

    var body: some View {
        SplitLayout(axis: split.axis, fractions: split.fractions, gap: DockTheme.gap) {
            ForEach(split.children) { child in
                NodeView(node: child)
            }
        }
        .overlay {
            GeometryReader { geo in
                let length = split.axis == .horizontal ? geo.size.width : geo.size.height
                let available = length - DockTheme.gap * CGFloat(split.children.count - 1)
                ForEach(0..<max(split.children.count - 1, 0), id: \.self) { i in
                    let before = split.fractions.prefix(i + 1).reduce(0, +)
                    let at = CGFloat(before) * available + CGFloat(i) * DockTheme.gap + DockTheme.gap / 2
                    DividerHandle(axis: split.axis)
                        .position(split.axis == .horizontal
                                  ? CGPoint(x: at, y: geo.size.height / 2)
                                  : CGPoint(x: geo.size.width / 2, y: at))
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = startFractions ?? split.fractions
                                    if startFractions == nil, ProcessInfo.processInfo.environment["BEARDOCK_LOG"] != nil { print("divider \(split.id) \(i) from \(value.startLocation)") }
                                    if startFractions == nil { startFractions = start }
                                    let t = split.axis == .horizontal ? value.translation.width : value.translation.height
                                    controller.layout.setFractions(split: split.id, Self.resized(start, at: i, by: t / max(available, 1), min: 80 / max(available, 1)))
                                }
                                .onEnded { _ in startFractions = nil }
                        )
                }
            }
        }
    }

    /// Moves the boundary after child i, keeping both sides at least `min`.
    static func resized(_ f: [Double], at i: Int, by delta: CGFloat, min: CGFloat) -> [Double] {
        var f = f
        let pair = f[i] + f[i + 1]
        let lo = Double(min), hi = pair - Double(min)
        guard lo < hi else { return f }
        f[i] = Swift.min(Swift.max(f[i] + Double(delta), lo), hi)
        f[i + 1] = pair - f[i]
        return f
    }
}

/// Lays children out along an axis by fraction, with a gap between each.
struct SplitLayout: Layout {
    var axis: SplitAxis
    var fractions: [Double]
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = axis == .horizontal
        let length = horizontal ? bounds.width : bounds.height
        let available = max(length - gap * CGFloat(subviews.count - 1), 0)
        var offset: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let f = i < fractions.count ? fractions[i] : 0
            let size = (available * CGFloat(f)).rounded()
            let rect = horizontal
                ? CGRect(x: bounds.minX + offset, y: bounds.minY, width: size, height: bounds.height)
                : CGRect(x: bounds.minX, y: bounds.minY + offset, width: bounds.width, height: size)
            sub.place(at: rect.origin, proposal: ProposedViewSize(rect.size))
            offset += size + gap
        }
    }
}

/// The invisible strip over a hairline that resizes the panels either side.
private struct DividerHandle: View {
    let axis: SplitAxis
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(DockTheme.accent.opacity(hovering ? 0.5 : 0))
            .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
            .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
            .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12).delay(hovering ? 0.15 : 0), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
    }
}

// MARK: Groups

struct GroupView: View {
    let group: DockGroup
    @Environment(DockController.self) private var controller
    @Environment(\.dockContent) private var content
    @Environment(\.dockOptions) private var options
    @Environment(\.dockNamespace) private var space

    var body: some View {
        // The tabs with something to show; the layout keeps the rest.
        let group = Self.visible(group, content.available)
        let lifted = controller.drag.map { $0.lifted && $0.panel == group.selected } ?? false
        // Where a panel just landed stays empty while the ghost flies in,
        // then fades up under it.
        let landing = controller.landing?.panel == group.selected

        let header = controller.layout.showsHeader(group)
        // Under the traffic lights, in a window without a title bar: the
        // bar stays (empty, if the title's hidden) so they've somewhere to sit.
        let corner = options.trafficLights > 0 && controller.layout.topLeadingGroupID == group.id

        VStack(spacing: 0) {
            if header {
                GroupHeader(group: group, leading: corner ? options.trafficLights : 0, movesWindow: corner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if corner {
                CornerBar(panel: group.selected)
            }
            content.view(group.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                // A plain .gesture, the lowest priority: any drag the panel's
                // own content handles (reordering rows, a slider, a text
                // selection, a web view) wins, so only a drag on its
                // background moves the panel. `dockDragDisabled()` stops it
                // for a region that has nothing of its own.
                .gesture(dragGesture(controller: controller, panel: group.selected))
                // The same menu as the title's, on the background, so a hidden
                // title can be brought back from anywhere empty. Outermost, so
                // content with a menu of its own keeps it.
                .contextMenu { PanelMenu(panel: group.selected, tabbed: group.panels.count > 1) }
                .opacity(lifted ? 0.18 : 1)
                .scaleEffect(lifted ? 0.985 : 1)
        }
        .background(DockTheme.panel)
        .overlay(alignment: .top) {
            if !header && !corner {
                HiddenTitleStrip(panel: group.selected)
                    .transition(.opacity)
            }
        }
        .overlay {
            if lifted {
                // The hole it left behind.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(DockTheme.faint)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .opacity(landing ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DockSpace.name)) } action: { controller.frames[group.id] = $0 }
        .modifier(MatchedGroup(id: group.id, space: space))
    }
}

extension GroupView {
    /// The group as drawn: without its unavailable panels, showing the
    /// selected one if it's available, else the first that is. All of
    /// them, if none is.
    static func visible(_ group: DockGroup, _ available: (PanelID) -> Bool) -> DockGroup {
        let panels = group.panels.filter(available)
        guard !panels.isEmpty else { return group }
        return DockGroup(id: group.id, panels: panels, selected: panels.contains(group.selected) ? group.selected : panels[0])
    }
}

/// Lets a group glide to its new place when it moves to another split.
private struct MatchedGroup: ViewModifier {
    let id: String
    let space: Namespace.ID?

    func body(content: Content) -> some View {
        if let space {
            content.matchedGeometryEffect(id: id, in: space)
        } else {
            content
        }
    }
}

@MainActor
func dragGesture(controller: DockController, panel: PanelID) -> some Gesture {
    DragGesture(minimumDistance: 5, coordinateSpace: .named(DockSpace.name))
        .onChanged { controller.dragChanged(panel: panel, start: $0.startLocation, location: $0.location) }
        .onEnded { _ in controller.dragEnded() }
}

/// A group's title, or its tabs when it has several, and the showing
/// panel's buttons. A title, a tab or the rest of the bar drags its panel;
/// in the bar under the traffic lights, the room left for them drags the
/// window.
struct GroupHeader: View {
    let group: DockGroup
    var leading: CGFloat = 0
    var movesWindow = false
    @Environment(DockController.self) private var controller
    @Environment(\.dockContent) private var content
    @Environment(\.dockOptions) private var options

    var body: some View {
        let single = group.panels.count == 1
        HStack(spacing: 2) {
            if single, let custom = content.header(group.selected) {
                custom
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                    // Lowest priority: the header's own buttons and chips win.
                    .gesture(dragGesture(controller: controller, panel: group.selected))
                    .contextMenu { PanelMenu(panel: group.selected, tabbed: false) }
                    // Its full width before the empty bar beside it gets any.
                    .layoutPriority(1)
            } else {
                ForEach(group.panels, id: \.self) { panel in
                    TabItem(panel: panel, selected: panel == group.selected, single: single)
                }
            }
            BarSpace(panel: group.selected, tabbed: !single)
            if let accessory = content.accessory(group.selected) {
                accessory
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: options.headerHeight)
        .padding(.leading, leading)
        .background(alignment: .leading) {
            if movesWindow && leading > 0 {
                WindowSpace().frame(width: leading)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
    }
}

/// The empty part of a bar: moves its panel.
private struct BarSpace: View {
    let panel: PanelID
    let tabbed: Bool
    @Environment(DockController.self) private var controller

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { PanelMenu(panel: panel, tabbed: tabbed) }
            .gesture(dragGesture(controller: controller, panel: panel))
    }
}

/// Where a title bar would be, in a window without one: moves the window,
/// and a double-click zooms it, as a title bar's would.
private struct WindowSpace: View {
    @Environment(\.dockOptions) private var options

    var body: some View {
        let space = Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        if options.cornerMovesWindow {
            space
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        } else {
            space
        }
    }
}

private struct TabItem: View {
    let panel: PanelID
    let selected: Bool
    let single: Bool
    @Environment(DockController.self) private var controller
    @Environment(\.dockContent) private var content
    @Environment(\.dockOptions) private var options
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = content.symbol(panel) {
                Image(systemName: symbol)
                    .font(.system(size: options.titleSize - 1, weight: .medium))
                    .foregroundStyle(selected ? DockTheme.secondary : DockTheme.faint)
            }
            Text(content.title(panel))
                .font(.system(size: options.titleSize, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DockTheme.headerText : DockTheme.secondary)
                .lineLimit(1)
            if content.closable(panel) {
                Button {
                    controller.close(panel)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: options.titleSize - 3, weight: .bold))
                        .foregroundStyle(DockTheme.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || (selected && !single) ? 1 : 0)
                .dockTip("Close \(content.title(panel))", options)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, content.closable(panel) ? 4 : 8)
        .frame(height: max(options.headerHeight - 8, 20))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(selected && !single ? 0.07 : (hovering ? 0.04 : 0)))
        )
        // Full titles: the empty bar beside them gives way first.
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(panel) }
        .contextMenu { PanelMenu(panel: panel, tabbed: !single) }
        // Over the bar's own drag, so a tab that isn't showing can be pulled
        // out directly. It needs 5 points of movement, so a click still
        // selects the tab.
        .highPriorityGesture(dragGesture(controller: controller, panel: panel))
    }
}

/// Right-click on a title, a tab, the strip of a panel without a title, or
/// a panel's background.
struct PanelMenu: View {
    let panel: PanelID
    let tabbed: Bool
    @Environment(DockController.self) private var controller
    @Environment(\.dockContent) private var content

    var body: some View {
        if controller.layout.hiddenTitles.contains(panel) {
            Button("Show Title", systemImage: "eye") { controller.setTitleHidden(panel, false) }
        } else {
            // With tabs the bar has to stay, so say when it'll take effect.
            Button(tabbed ? "Hide Title When on Its Own" : "Hide Title", systemImage: "eye.slash") { controller.setTitleHidden(panel, true) }
        }
        if controller.layout.isFloating(panel) {
            Button("Put Back in Main Window", systemImage: "rectangle.portrait.and.arrow.forward") { controller.putBack(panel) }
        } else if controller.layout.canFloat(panel) {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { controller.openInWindow(panel) }
        }
        if content.closable(panel) {
            Divider()
            Button("Close \(content.title(panel))", systemImage: "xmark") { controller.close(panel) }
        }
    }
}

/// In place of the title bar for a panel that hides its title: a strip
/// along the top that shows a grab handle on hover, to drag the panel by and
/// right-click for the title back.
private struct HiddenTitleStrip: View {
    let panel: PanelID
    @Environment(DockController.self) private var controller
    @Environment(\.dockOptions) private var options
    @State private var hovering = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(hovering ? 0.28 : 0))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(dragGesture(controller: controller, panel: panel))
        .contextMenu { PanelMenu(panel: panel, tabbed: false) }
        .dockTip("Drag to move this panel. Right-click to show its title.", options)
    }
}

/// The bar of a title-less panel under the traffic lights: empty, moving
/// the window (or the panel, with a title bar), with the grab handle on
/// hover to move the panel by. In Threadbear that's the sidebar's bar, the
/// one place left to grab the window by.
private struct CornerBar: View {
    let panel: PanelID
    @Environment(\.dockOptions) private var options

    var body: some View {
        HStack(spacing: 0) {
            if options.cornerMovesWindow {
                WindowSpace()
            } else {
                Color.clear.frame(width: options.trafficLights)
                BarSpace(panel: panel, tabbed: false)
            }
            HiddenTitleStrip(panel: panel)
                .frame(width: 60)
            Color.clear.frame(width: 12)
        }
        .frame(height: options.headerHeight)
    }
}

extension View {
    /// Keeps a region of a panel from picking the panel up when dragged,
    /// for content with no drag of its own (a canvas, a read-only list)
    /// where moving the panel would surprise. The header still moves it.
    public func dockDragDisabled() -> some View {
        // A drag that does nothing, nearer the pointer than the dock's.
        gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
    }
}
