import AppKit
import SwiftUI
import ThreadbareCore

/// A thread's sub-agents, as indented rows under its sidebar row (which
/// ones: `SubagentRows.visible`).
struct SubagentList: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    /// The section the thread is under, so the rows' ids are unique when a
    /// thread changes section (see SectionRow).
    let section: String

    var body: some View {
        let selected = app.subagentSelection?.threadId == thread.id ? app.subagentSelection?.subagentId : nil
        let rows = SubagentRows.visible(thread, threadSelected: app.selection == thread.id, selectedSubagent: selected, now: app.now)
        ForEach(rows.map { SubagentRowID(section: section, threadId: thread.id, row: $0) }) { item in
            SubagentRowView(threadId: thread.id, row: item.row)
        }
    }
}

private struct SubagentRowID: Identifiable {
    let section: String
    let threadId: String
    let row: SubagentRow
    var id: String { section + "/" + threadId + "/sub/" + row.id }
}

struct SubagentRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    let threadId: String
    let row: SubagentRow
    @State private var hovering = false
    @State private var pressed = false

    /// Each level in by about the width of the glyph and its gap, so a
    /// child's glyph sits under its parent's title.
    static let indent: CGFloat = 18

    private var subagent: Subagent { row.subagent }
    private var isSelected: Bool { app.subagentSelection == SubagentRef(threadId: threadId, subagentId: subagent.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(7)) {
            glyph
                .frame(width: zoomed(11), height: zoomed(11))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: zoomed(2)) {
                HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                    Text(SubagentRows.title(subagent))
                        .font(.system(size: TypeScale.sidebarPreview))
                        // A finished one steps back; the running ones are
                        // what's worth reading.
                        .foregroundStyle(subagent.isRunning || isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: zoomed(6))
                    duration
                        .font(.system(size: TypeScale.sidebarMeta))
                        .monospacedDigit()
                        .foregroundStyle(SidebarMetrics.faint)
                }
                Text(SubagentRows.detail(subagent))
                    .font(.system(size: TypeScale.sidebarMeta + 1))
                    .foregroundStyle(subagent.status == .failed ? AnyShapeStyle(Color(nsColor: Theme.failed)) : AnyShapeStyle(SidebarMetrics.faint))
                    .lineLimit(1)
            }
        }
        // In from the thread's title, so the rows read as its own.
        .padding(EdgeInsets(top: 5, leading: SidebarMetrics.leading + 8 + Self.indent * CGFloat(row.depth),
                            bottom: 6, trailing: SidebarMetrics.trailing))
        .background(background, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        // Selects on mouse down, as thread rows do.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard !pressed else { return }
            pressed = true
            app.selectSubagent(threadId: threadId, subagentId: subagent.id)
        }.onEnded { _ in pressed = false })
        .onHover { hovering = $0 }
        .tip(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sub-agent \(SubagentRows.title(subagent)), \(SubagentRows.statusText(subagent))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { app.selectSubagent(threadId: threadId, subagentId: subagent.id) }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(activeState == .key ? 0.08 : 0.06) }
        return hovering ? SidebarMetrics.hover : .clear
    }

    @ViewBuilder
    private var glyph: some View {
        switch subagent.status {
        case .running:
            // Grey, like a thread's background work: the accent spinner is
            // the thread's own turn.
            SpinnerMark(color: .secondaryLabelColor)
        case .completed:
            Image(systemName: "checkmark").font(.system(size: zoomed(9), weight: .semibold)).foregroundStyle(SidebarMetrics.faint)
        case .failed:
            Image(systemName: "xmark").font(.system(size: zoomed(9), weight: .semibold)).foregroundStyle(Color(nsColor: Theme.failed))
        case .stopped:
            Image(systemName: "minus").font(.system(size: zoomed(9), weight: .semibold)).foregroundStyle(SidebarMetrics.faint)
        }
    }

    @ViewBuilder
    private var duration: some View {
        if subagent.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SubagentRows.duration(subagent, now: context.date))
            }
        } else {
            Text(SubagentRows.duration(subagent, now: app.now))
        }
    }

    private var tooltip: String {
        var parts = [SubagentRows.statusText(subagent)]
        if let type = subagent.agentType, !type.isEmpty { parts.insert(type, at: 0) }
        if let uses = subagent.toolUses, uses > 0 { parts.append(uses == 1 ? "1 tool call" : "\(uses) tool calls") }
        return parts.joined(separator: " · ")
    }
}

/// Above a sub-agent's transcript: a way back to its thread, then what it
/// is and how it's getting on. The transcript has no composer.
struct SubagentHeader: View {
    @Environment(AppModel.self) private var app
    let ref: SubagentRef

    var body: some View {
        let thread = app.threads[ref.threadId]
        let subagent = thread?.subagents.first { $0.id == ref.subagentId }
        HStack(alignment: .center, spacing: zoomed(10)) {
            Button {
                app.select(ref.threadId)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(RowIconButtonStyle())
            .tip("Back to the thread")
            VStack(alignment: .leading, spacing: zoomed(2)) {
                Text(subagent.map(SubagentRows.title) ?? "Sub-agent")
                    .font(.system(size: TypeScale.sidebarTitle, weight: .semibold))
                    .lineLimit(1)
                Text(meta(subagent, thread: thread))
                    .font(.system(size: TypeScale.sidebarMeta + 1))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, zoomed(14))
        .padding(.vertical, zoomed(8))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    /// "Explore · Running in the background · 4 tool calls · in Fix the build"
    private func meta(_ subagent: Subagent?, thread: ThreadSummary?) -> String {
        var parts: [String] = []
        if let subagent {
            if let type = subagent.agentType, !type.isEmpty { parts.append(type) }
            parts.append(SubagentRows.statusText(subagent))
            if let uses = subagent.toolUses, uses > 0 { parts.append(uses == 1 ? "1 tool call" : "\(uses) tool calls") }
        }
        if let thread { parts.append("from " + (thread.title.isEmpty ? "Untitled" : thread.title)) }
        return parts.joined(separator: " · ")
    }
}
