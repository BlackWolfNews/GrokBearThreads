import BearDock
import SwiftUI

/// Stand-ins for Threadbear's panels: enough texture to see what's where.
struct MockPanel: View {
    let panel: PanelID

    var body: some View {
        switch panel {
        case "threads": ThreadsMock()
        case "transcript": TranscriptMock()
        case "highlights": HighlightsMock()
        case "convex": ConvexMock()
        case "worktrees": WorktreesMock()
        case "terminal": TerminalMock()
        case "files": FilesMock()
        default: Text(panel).foregroundStyle(.secondary)
        }
    }
}

private let dim = Color(white: 0.6)
private let faint = Color(white: 0.42)

private struct ThreadsMock: View {
    let rows = [
        ("Docking library and demo app", "threadbear", "now"),
        ("Mobile app for Threadbear", "threadbear", "1m"),
        ("Tidy the pool settings screen", "misc", "8m"),
        ("Resume Convex state machine work", "convex-native-v7", "14h"),
        ("Next video after Nippon", "tandem", "15h"),
        ("Projects page grid view", "misc", "15h"),
        ("Poddle: download one episode", "poddle", "1d"),
    ]

    /// Rows are buttons, as in the app, to try that a click on one still
    /// lands with the dock's press timing behind the panel.
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Button {
                    selected = i
                    if ProcessInfo.processInfo.environment["BEARDOCK_LOG"] != nil { print("select row \(i)") }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(row.1).font(.system(size: 11)).foregroundStyle(faint)
                        }
                        Spacer(minLength: 4)
                        Text(row.2).font(.system(size: 11)).foregroundStyle(faint)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(i == selected ? 0.07 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
    }
}

private struct TranscriptMock: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model tests pass. Now the views: a controller that owns the layout and the drag, a recursive view for the tree, and an overlay for the ghost, the preview and the compass.")
                Text("Dragging a panel lifts it into a small floating card under the pointer. Over another panel, the side you're nearest lights up; in the middle, a compass lets you choose a side, a tab or a swap.")
                HStack {
                    Spacer()
                    Text("Can you make it shrink a bit as you pick it up?")
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                }
                Text("Done. It scales to about 280 points wide with the point you grabbed kept under the pointer.")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Color(white: 0.85))
            .lineSpacing(3)
            .frame(maxWidth: 560, alignment: .leading)
            Spacer()
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.14))
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.03)))
                .overlay(alignment: .topLeading) { Text("Message").font(.system(size: 13)).foregroundStyle(faint).padding(14) }
                .frame(maxWidth: 560)
                .frame(height: 84)
        }
        .padding(20)
    }
}

private struct HighlightsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Building a docking library with a demo app, so dragging panels can be tuned before it goes into Threadbear.")
                .font(.system(size: 12.5)).foregroundStyle(dim).lineSpacing(2)
            Label("Changes", systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold)).foregroundStyle(dim).padding(.top, 6)
            ForEach(["DockLayout: tree, moves, tidy-up", "Ghost, preview and compass", "Demo app with mock panels"], id: \.self) { line in
                HStack(spacing: 8) {
                    Text("a1b2c3d").font(.system(size: 11, design: .monospaced)).foregroundStyle(faint)
                    Text(line).font(.system(size: 12)).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct ConvexMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("threads").font(.system(size: 12, weight: .semibold))
                Text("214 documents").font(.system(size: 11)).foregroundStyle(faint)
                Spacer()
            }
            .padding(12)
            ForEach(0..<9, id: \.self) { i in
                HStack(spacing: 12) {
                    Text("k17\(i)f…").font(.system(size: 11, design: .monospaced)).foregroundStyle(faint)
                    Text(["running", "idle", "needsYou", "idle", "archived"][i % 5]).font(.system(size: 11.5))
                    Spacer()
                    Text("\(i + 2)m").font(.system(size: 11)).foregroundStyle(faint)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(i % 2 == 0 ? Color.white.opacity(0.025) : .clear)
            }
            Spacer()
        }
    }
}

/// Rows you can reorder by dragging them: a drag the panel handles itself,
/// so it must win over the dock's. Dragging the space under the rows still
/// moves the panel.
private struct WorktreesMock: View {
    @State private var rows = ["thread/419a9c2a  dock", "thread/89b52654  convex backend", "thread/2f1e77c0  pool settings", "thread/7c3d9e11  website"]
    @State private var dragging: String?
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Drag a row to reorder it")
                .font(.system(size: 11)).foregroundStyle(faint)
                .padding(.bottom, 6)
            ForEach(rows, id: \.self) { w in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(faint)
                    Text(w).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: rowHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(dragging == w ? 0.1 : 0.03)))
                .padding(.vertical, 1)
                .offset(y: dragging == w ? offset : 0)
                .zIndex(dragging == w ? 1 : 0)
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            dragging = w
                            offset = v.translation.height
                        }
                        .onEnded { v in
                            if let from = rows.firstIndex(of: w) {
                                let to = max(0, min(rows.count - 1, from + Int((v.translation.height / (rowHeight + 2)).rounded())))
                                withAnimation(.snappy) {
                                    rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                    dragging = nil
                                    offset = 0
                                }
                            }
                        }
                )
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct TerminalMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("$ swift test").foregroundStyle(Color(white: 0.85))
            Text("✔ Test run with 13 tests passed").foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.5))
            Text("$ swift run DockDemo").foregroundStyle(Color(white: 0.85))
            Text("Building for debugging...").foregroundStyle(faint)
            Spacer()
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.25))
    }
}

private struct FilesMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(["dock/", "  Package.swift", "  Sources/BearDock/", "    DockLayout.swift", "    DockController.swift", "    DockView.swift", "    DragOverlay.swift"], id: \.self) { f in
                Text(f).font(.system(size: 12, design: .monospaced)).foregroundStyle(f.hasSuffix("/") ? dim : Color(white: 0.85))
            }
            Spacer()
        }
        .padding(14)
    }
}
