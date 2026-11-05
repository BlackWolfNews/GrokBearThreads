import SwiftUI
import ThreadbearCore

/// Settings > Runners: the machines Threadbear runs threads on, and which
/// one new threads start on. Deliberately thin: a runner is set up on its
/// own machine (its runner.json, INSTALL.md section 6 for a Linux server),
/// so naming, adding or pairing one is a job for an agent, which the ⓘ
/// says. The one control is the default, which is this Mac's own choice.
struct RunnersSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            SettingsSection("Default runner",
                            about: "Where a new thread runs unless you pick another machine on the composer. This is this Mac's own choice.",
                            ask: "change it, or to set up another machine to run threads on.") {
                LabeledContent("New threads start on") {
                    Picker("New threads start on", selection: defaultBinding) {
                        Label("This Mac", systemImage: app.selfRunnerIcon).tag(String?.none)
                        ForEach(app.remoteRunners) { runner in
                            Label(runner.name, systemImage: RunnerIcon.symbol(runner.icon)).tag(String?.some(runner.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .tip("Where a new thread runs unless you pick another machine on the composer")
                }
            }

            SettingsSection("Runners",
                            about: "The machines your threads can run on. Each runner is set up on its own machine.",
                            ask: "add one, rename one, pair it with this Mac or change how it runs. It knows how, and a Linux server's steps are in INSTALL.md.") {
                RunnerRow(icon: app.selfRunnerIcon, name: selfName, status: "This Mac", isDefault: app.defaultRunnerId == nil)
                ForEach(app.remoteRunners) { runner in
                    RunnerRow(icon: RunnerIcon.symbol(runner.icon), name: runner.name, status: status(runner), isDefault: app.defaultRunnerId == runner.id)
                }
            }

            SettingsSection("Other machines' threads",
                            about: "Threads on other machines open through this Mac's runner and Convex, with no network link between the machines. Tool output stays on the machine that ran it for now. Connecting directly reaches the other machine over Tailscale instead, and needs it paired with this Mac.",
                            ask: "explain how other machines' threads reach this Mac, or pair one for a direct connection.") {
                @Bindable var app = app
                Toggle("Connect to other machines directly", isOn: $app.directRemoteLink)
                    .tip("Open other machines' threads over Tailscale instead of through Convex")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .scrollDisabled(true)
    }

    private var defaultBinding: Binding<String?> {
        Binding(get: { app.defaultRunnerId }, set: { app.setDefaultRunner($0) })
    }

    /// This runner's own name, as other machines see it ("M5").
    private var selfName: String { app.runners.first(where: \.isSelf)?.name ?? "This Mac" }

    private func status(_ runner: RemoteRunner) -> String {
        if app.directRemoteLink, runner.tokenFile == nil { return "Not paired with this Mac" }
        return runner.online ? "Online" : "Offline"
    }
}

/// A runner: its icon, name and how it is, with a star on the default.
private struct RunnerRow: View {
    let icon: String
    let name: String
    let status: String
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(name)
            if isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .tip("New threads start here")
                    .accessibilityLabel("Default")
            }
            Spacer(minLength: 8)
            Text(status)
                .foregroundStyle(.secondary)
        }
    }
}
