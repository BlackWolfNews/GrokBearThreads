import AppKit
import SwiftUI
import ThreadbearCore

/// The rail's updates icon: there only while the app or the runner has an
/// update on its way (or one failed), so most of the time the rail looks as
/// it always did. A small accent dot only when it needs Mike: a launch.mjs
/// only he can install. Anything else (building, ready, a failed build that
/// retries once main is fixed) gets a grey dot, so he can see something's
/// going on without it asking him to act.
struct UpdatesActivityButton: View {
    @Environment(AppModel.self) private var app
    private var updater: AppUpdater { AppUpdater.shared }

    var body: some View {
        @Bindable var app = app
        let side = UpdatesPopover.appSide(updater)
        if UpdatesText.shown(app: side, runner: app.runnerUpdates) {
            ActivityButton(symbol: "arrow.down.circle", title: UpdatesText.tooltip(app: side, runner: app.runnerUpdates),
                           dot: UpdatesText.needsYou(app: side, runner: app.runnerUpdates), quietDot: true,
                           active: app.updatesPopoverShown) {
                app.updatesPopoverShown.toggle()
            }
            .popover(isPresented: $app.updatesPopoverShown, arrowEdge: .trailing) {
                UpdatesPopover().environment(app)
            }
        }
    }
}

/// What's on its way for the app and for the runner, with the one or two
/// things Mike can do about it.
struct UpdatesPopover: View {
    @Environment(AppModel.self) private var app
    private var updater: AppUpdater { AppUpdater.shared }

    static func appSide(_ updater: AppUpdater) -> UpdatesText.AppSide {
        UpdatesText.AppSide(running: updater.running?.short, staged: updater.staged?.short,
                            building: updater.building != nil, failed: updater.failed != nil && updater.staged == nil)
    }

    var body: some View {
        let side = Self.appSide(updater)
        let runner = app.runnerUpdates
        VStack(alignment: .leading, spacing: zoomed(14)) {
            section("App") {
                line(UpdatesText.appLine(side))
                if side.staged != nil {
                    Button("Restart to Update") { updater.restartToUpdate() }
                        .tip("Quit and reopen on the new version. Running threads carry on in the runner.")
                } else if side.failed {
                    Button("Show the Log") { NSWorkspace.shared.open(URL(fileURLWithPath: AppUpdater.logPath)) }
                        .tip("Open the update build's log, to see why it failed")
                }
            }
            section("Runner") {
                if let runner {
                    let lines = [UpdatesText.buildLine(runner), UpdatesText.oldRunnersLine(runner), UpdatesText.launcherLine(runner)]
                    if lines.allSatisfy({ $0 == nil }) { line("The runner is up to date.") }
                    if let build = lines[0] { line(build) }
                    if let old = lines[1] {
                        line(old)
                        // The threads on the previous version, to jump to.
                        ForEach(runner.oldRunners.flatMap(\.threads), id: \.self) { id in
                            Button {
                                app.select(id)
                                app.updatesPopoverShown = false
                            } label: {
                                Text(app.threads[id]?.title.nonEmpty ?? String(id.prefix(8)))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: zoomed(12)))
                            .tip("Open this thread")
                        }
                    }
                    if let launcher = lines[2] {
                        line(launcher)
                        let command = UpdatesText.installCommand(checkout: updater.running?.checkout)
                        HStack(spacing: zoomed(6)) {
                            Text(command)
                                .font(.system(size: zoomed(11), design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Button("Copy") { app.copyToPasteboard(command) }
                                .tip("Copy the command, to run in Terminal")
                        }
                    }
                } else {
                    ForEach(UpdatesText.runnerLines(nil), id: \.self) { line($0) }
                }
            }
        }
        .padding(zoomed(16))
        .frame(width: zoomed(340), alignment: .leading)
    }

    // Small headings, as the Usage popover groups its accounts.
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: zoomed(7)) {
            Text(title)
                .font(.system(size: zoomed(11), weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: zoomed(12)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
