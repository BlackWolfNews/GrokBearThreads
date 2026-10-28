import AppKit
import SwiftUI

/// What the app gives the dock for each panel: its title, an SF Symbol, and its view.
public struct DockContent {
    public var title: (PanelID) -> String
    public var symbol: (PanelID) -> String?
    public var view: (PanelID) -> AnyView
}

enum DockSpace {
    static let name = "BearDock"
}

enum DockTheme {
    static let panel = Color(white: 0.125)
    /// Shows through the 1 pt gaps between panels, as the hairlines.
    static let hairline = Color(white: 0.2)
    static let headerText = Color(white: 0.93)
    static let secondary = Color(white: 0.62)
    static let faint = Color(white: 0.45)
    static let accent = Color(red: 0.36, green: 0.62, blue: 1)
    static let headerHeight: CGFloat = 32
    static let gap: CGFloat = 1
}

/// The whole docking area: the layout's tree of splits and groups, with the
/// drag's ghost, drop preview and compass drawn over it.
public struct DockView: View {
    let controller: DockController
    let content: DockContent
    @Namespace private var space

    public init<C: View>(
        controller: DockController,
        title: @escaping (PanelID) -> String,
        symbol: @escaping (PanelID) -> String? = { _ in nil },
        @ViewBuilder content: @escaping (PanelID) -> C
    ) {
        self.controller = controller
        self.content = DockContent(title: title, symbol: symbol, view: { AnyView(content($0)) })
    }

    public var body: some View {
        NodeView(node: controller.layout.root)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DockTheme.hairline)
            .overlay(alignment: .topLeading) {
                DragOverlay()
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(DockSpace.name))
            .onGeometryChange(for: CGRect.self) { CGRect(origin: .zero, size: $0.size) } action: { controller.bounds = $0 }
            .environment(controller)
            .environment(\.dockContent, content)
            .environment(\.dockNamespace, space)
    }
}

extension EnvironmentValues {
    @Entry var dockContent = DockContent(title: { $0 }, symbol: { _ in nil }, view: { _ in AnyView(EmptyView()) })
    @Entry var dockNamespace: Namespace.ID?
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
    @Environment(\.dockNamespace) private var space

    var body: some View {
        let lifted = controller.drag.map { $0.lifted && $0.panel == group.selected } ?? false
        // Where a panel just landed stays empty while the ghost flies in,
        // then fades up under it.
        let landing = controller.landing?.panel == group.selected

        VStack(spacing: 0) {
            GroupHeader(group: group)
            content.view(group.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(controller: controller, panel: group.selected))
                .opacity(lifted ? 0.18 : 1)
                .scaleEffect(lifted ? 0.985 : 1)
        }
        .background(DockTheme.panel)
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

/// A group's title, or its tabs when it has several. Each tab can be dragged
/// out on its own; the body drags the one showing.
private struct GroupHeader: View {
    let group: DockGroup
    @Environment(DockController.self) private var controller

    var body: some View {
        HStack(spacing: 2) {
            ForEach(group.panels, id: \.self) { panel in
                TabItem(panel: panel, selected: panel == group.selected, single: group.panels.count == 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: DockTheme.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct TabItem: View {
    let panel: PanelID
    let selected: Bool
    let single: Bool
    @Environment(DockController.self) private var controller
    @Environment(\.dockContent) private var content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = content.symbol(panel) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? DockTheme.secondary : DockTheme.faint)
            }
            Text(content.title(panel))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DockTheme.headerText : DockTheme.secondary)
                .lineLimit(1)
            Button {
                controller.close(panel)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DockTheme.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || (selected && !single) ? 1 : 0)
            .help("Close")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(selected && !single ? 0.07 : (hovering ? 0.04 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(panel) }
        .gesture(dragGesture(controller: controller, panel: panel))
    }
}
