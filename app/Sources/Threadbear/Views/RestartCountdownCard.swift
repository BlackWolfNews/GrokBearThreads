import SwiftUI

/// The few seconds before the app restarts itself onto a staged build
/// (AppUpdater.considerAutoRestart): a card at the top of the window that
/// counts down, with Cancel to stay put and Restart to go now.
struct RestartCountdownCard: View {
    private var updater: AppUpdater { AppUpdater.shared }

    var body: some View {
        if let left = updater.countdown {
            HStack(spacing: zoomed(10)) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                // Monospaced digits, so the line doesn't shift as it counts.
                Text("Restarting Threadbear to update in \(left)")
                    .monospacedDigit()
                    .lineLimit(1)
                Button("Cancel") { updater.cancelCountdown() }
                    .tip("Stay on this version. Restart to Update in the Threadbear menu still takes it.")
                Button("Restart") { updater.restartToUpdate() }
                    .tip("Restart onto the new version now. Running threads carry on in the runner.")
            }
            .font(.system(size: TypeScale.label))
            .padding(.leading, zoomed(14))
            .padding(.trailing, zoomed(10))
            .padding(.vertical, zoomed(8))
            // Solid: a material let the transcript under it show through.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: zoomed(10)))
            .overlay(RoundedRectangle(cornerRadius: zoomed(10)).strokeBorder(Color(nsColor: Theme.hairline), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            // Just under the panels' bars, clear of the traffic lights.
            .padding(.top, PaneHeader<EmptyView, EmptyView>.height + zoomed(10))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
