import AppKit
import SwiftUI
import ThreadbareCore

/// The Settings window (⌘,): the runner's settings, in the grouped form
/// every Mac app's settings use. All of it lives in the runner; this only
/// shows it and sends changes.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModelSettings()
                .tabItem { Label("Models", systemImage: "sparkles") }
                .tag(SettingsTab.models)
        }
        .frame(width: 540)
        .background(SettingsWindowFinder())
    }
}

/// What both tabs show until there are settings to show.
private struct SettingsGate<Content: View>: View {
    @Environment(AppModel.self) private var app
    @ViewBuilder var content: (RunnerSettings) -> Content

    var body: some View {
        if let settings = app.runnerSettings {
            content(settings)
        } else {
            Form {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 140)
        }
    }

    private var message: String {
        if app.settingsUnsupported { return "This runner is too old for settings. It gets them when it next updates." }
        if app.connection != .connected { return "Not connected to the runner." }
        return "Loading…"
    }
}

/// The last change that didn't take, under the form it came from.
private struct SettingsErrorRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.settingsError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsGate { settings in
            Form {
                Section {
                    LabeledContent("Default folder") {
                        HStack(spacing: 8) {
                            Text(SettingsText.folder(settings.defaultCwd))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(settings.defaultCwd)
                            Button("Choose…") { chooseFolder(from: settings.defaultCwd) }
                        }
                    }
                } footer: {
                    Footnote("Where a new thread starts when you don't pick a folder.")
                }

                Section {
                    LabeledContent("Release an idle CLI after") {
                        Stepper(value: binding(settings.idleMinutes) { SettingsUpdate(idleMinutes: $0) }, in: 1...600, step: 5) {
                            Text(settings.idleMinutes == 1 ? "1 minute" : "\(settings.idleMinutes) minutes")
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Most CLIs live at once") {
                        Stepper(value: binding(settings.maxLiveCLIs) { SettingsUpdate(maxLiveCLIs: $0) }, in: 1...20) {
                            Text("\(settings.maxLiveCLIs)")
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Footnote("Each live CLI uses about 400 MB. Past the limit, the one that's been idle longest is released early.")
                }

                Section {
                    Toggle("Follow main", isOn: binding(settings.followMain) { SettingsUpdate(followMain: $0) })
                } footer: {
                    Footnote("The runner builds each new commit on main and restarts onto it once no thread is busy. A change here takes effect when the runner next restarts.")
                }

                Section {
                    LabeledContent("Runner version") {
                        Text(app.runnerVersion.isEmpty ? "Not connected" : app.runnerVersion)
                            .textSelection(.enabled)
                    }
                }

                SettingsErrorRow()
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            // The window fits the form; a scroller beside it is just noise
            // (General's last section, with no footer, ran a few points over).
            .scrollIndicators(.never)
            .scrollDisabled(true)
        }
    }

    private func binding<T>(_ value: T, _ update: @escaping (T) -> SettingsUpdate) -> Binding<T> {
        Binding(get: { value }, set: { app.updateSettings(update($0)) })
    }

    private func chooseFolder(from current: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            app.updateSettings(SettingsUpdate(defaultCwd: url.path))
        }
    }
}

// MARK: Models

private struct ModelSettings: View {
    @Environment(AppModel.self) private var app
    /// What's typed into the key field. Held only until it's sent, then
    /// cleared: the app never keeps the key.
    @State private var keyDraft = ""
    @State private var changingKey = false
    @State private var savingKey = false
    @State private var budgetDraft: Double = 1

    var body: some View {
        SettingsGate { settings in
            Form {
                Section {
                    keyRow(settings.models.openRouterKey)
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Footnote("With a key set, Threadbear sends the start of each new thread to OpenRouter and the model's provider to write its title. Later it will send more for summaries and triage. Threads in private folders are never sent.")
                }

                Section {
                    LabeledContent("Daily budget") {
                        // "$" and a number rather than a currency format,
                        // which reads "USD 1.00" outside the US.
                        HStack(spacing: 4) {
                            Text("$")
                                .foregroundStyle(.secondary)
                            TextField("Daily budget", value: $budgetDraft, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .onSubmit { saveBudget(settings) }
                        }
                    }
                    LabeledContent("Spent today", value: SettingsText.money(settings.models.spentTodayUsd))
                    LabeledContent("Spent this month", value: SettingsText.money(settings.models.spentMonthUsd))
                } header: {
                    Text("Spending")
                } footer: {
                    Footnote("Calls stop for the day once the budget is spent. Set it to $0 to stop them altogether.")
                }
                .onAppear { budgetDraft = settings.models.dailyBudgetUsd }
                .onChange(of: settings.models.dailyBudgetUsd) { _, new in budgetDraft = new }

                Section {
                    if settings.models.privateFolders.isEmpty {
                        Text("None yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.models.privateFolders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                app.updateSettings(SettingsUpdate(privateFolders: settings.models.privateFolders.filter { $0 != folder }))
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                    Button("Add Folder…") { addPrivateFolder(settings.models.privateFolders) }
                } header: {
                    Text("Private folders")
                } footer: {
                    Footnote("Nothing from threads in these folders, or in folders inside them, is sent.")
                }

                SettingsErrorRow()
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            // The window fits the form; a scroller beside it is just noise
            // (General's last section, with no footer, ran a few points over).
            .scrollIndicators(.never)
            .scrollDisabled(true)
        }
    }

    @ViewBuilder
    private func keyRow(_ key: RunnerSettings.Key) -> some View {
        if key.set && !changingKey {
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    Text(key.hint.map { "Set, ends in \($0)" } ?? "Set")
                        .foregroundStyle(.secondary)
                    Button("Change") { changingKey = true }
                    Button("Remove") { Task { await app.setOpenRouterKey(nil) } }
                }
            }
        } else {
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    SecureField("Key", text: $keyDraft, prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onSubmit(saveKey)
                    if changingKey {
                        Button("Cancel") {
                            keyDraft = ""
                            changingKey = false
                        }
                    }
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savingKey)
                }
            }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !savingKey else { return }
        savingKey = true
        Task {
            let saved = await app.setOpenRouterKey(key)
            savingKey = false
            // Cleared either way once the runner has answered: a key that
            // was refused is typed again, not kept around.
            keyDraft = ""
            if saved { changingKey = false }
        }
    }

    private func saveBudget(_ settings: RunnerSettings) {
        guard budgetDraft != settings.models.dailyBudgetUsd else { return }
        app.updateSettings(SettingsUpdate(dailyBudgetUsd: budgetDraft))
    }

    private func addPrivateFolder(_ current: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var folders = current
        for url in panel.urls {
            let folder = SettingsText.folder(url.path)
            if !folders.contains(folder) { folders.append(folder) }
        }
        app.updateSettings(SettingsUpdate(privateFolders: folders))
    }
}

/// A grey line under a section.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Remembers the Settings window, so the automation hook can bring it up,
/// keep it behind and capture it like the main window.
private struct SettingsWindowFinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { SettingsWindow.current = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { SettingsWindow.current = window }
    }
}

@MainActor
enum SettingsWindow {
    static weak var current: NSWindow?
}
