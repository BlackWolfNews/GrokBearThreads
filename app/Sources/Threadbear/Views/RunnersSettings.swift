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
            Section {
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

            Section {
                RunnerRow(icon: app.selfRunnerIcon, name: selfName, status: "This Mac", isDefault: app.defaultRunnerId == nil)
                ForEach(app.remoteRunners) { runner in
                    RunnerRow(icon: RunnerIcon.symbol(runner.icon), name: runner.name, status: status(runner), isDefault: app.defaultRunnerId == runner.id)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Runners")
                    InfoTip("Each runner is set up on its own machine. To add one, rename one, pair it with this Mac or change how it runs, ask your agent: it knows how, and a Linux server's steps are in INSTALL.md.")
                }
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
        if runner.tokenFile == nil { return "Not paired with this Mac" }
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
