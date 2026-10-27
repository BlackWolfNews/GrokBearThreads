import AppKit
import SwiftUI
import ThreadbareCore

/// The thread's actions (from its folder's patches) as chips above the
/// composer's text. A command action runs in the folder and its output
/// lands in the transcript; a prompt action sends its message.
struct ActionChips: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: zoomed(6)) {
                ForEach(thread.actions) { action in
                    ActionChip(action: action, running: app.isRunning(action: action, in: thread.id)) {
                        app.runAction(action, in: thread.id)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct ActionChip: View {
    let action: Action
    let running: Bool
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: zoomed(5)) {
                if running {
                    SpinnerMark(color: .secondaryLabelColor).frame(width: zoomed(11), height: zoomed(11))
                } else {
                    // The patch glyph for a command, a bubble for a message.
                    Image(systemName: action.kind == .prompt ? "text.bubble" : "square.dashed")
                        .font(.system(size: zoomed(11), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(action.title)
                    .foregroundStyle(.primary)
            }
            .font(.system(size: TypeScale.chip))
            .padding(.horizontal, zoomed(9))
            .padding(.vertical, zoomed(4))
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .help(action.note ?? action.command ?? action.prompt ?? action.title)
    }
}
