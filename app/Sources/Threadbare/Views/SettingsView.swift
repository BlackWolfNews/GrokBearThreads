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
            PoolSettings()
                .tabItem { Label("Pools", systemImage: "square.stack") }
                .tag(SettingsTab.pools)
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
                                .tip(settings.defaultCwd)
                            Button("Choose…") { chooseFolder(from: settings.defaultCwd) }
                                .tip("Pick the folder new threads start in")
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
                        .tip("A thread's CLI is stopped after this long with nothing to do, and picks up where it left off when you next send")
                    }
                    LabeledContent("Most CLIs live at once") {
                        Stepper(value: binding(settings.maxLiveCLIs) { SettingsUpdate(maxLiveCLIs: $0) }, in: 1...20) {
                            Text("\(settings.maxLiveCLIs)")
                                .monospacedDigit()
                        }
                        .tip("How many threads can have a CLI running at once")
                    }
                } footer: {
                    Footnote("Each live CLI uses about 400 MB. Past the limit, the one that's been idle longest is released early.")
                }

                Section {
                    Toggle("Follow main", isOn: binding(settings.followMain) { SettingsUpdate(followMain: $0) })
                        .tip("Update the runner by itself from each new commit on main")
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
                    Footnote("With a key set, Threadbear sends the start of each new thread to OpenRouter to write its title, and later more for summaries and triage. It only uses providers that keep nothing. Threads in private folders are never sent.")
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
                                .tip("Most to spend on OpenRouter in a day, in US dollars. Return saves it.")
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
                            .tip("Stop keeping this folder private")
                        }
                    }
                    Button("Add Folder…") { addPrivateFolder(settings.models.privateFolders) }
                        .tip("Keep a folder's threads from ever being sent to OpenRouter")
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
                        .tip("Put in a different key")
                    Button("Remove") { Task { await app.setOpenRouterKey(nil) } }
                        .tip("Forget the key: titles and summaries stop until there's a new one")
                }
            }
        } else {
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    SecureField("Key", text: $keyDraft, prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onSubmit(saveKey)
                        .tip("Your OpenRouter API key. It goes to the runner, not this app.")
                    if changingKey {
                        Button("Cancel") {
                            keyDraft = ""
                            changingKey = false
                        }
                        .tip("Keep the key you have")
                    }
                    Button("Save", action: saveKey)
                        .tip("Send the key to the runner")
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

// MARK: Pools

/// Settings › Pools (docs/pools-plan.md): the pools, and for the one picked,
/// its name, which logins are in it and in what order, and the folders
/// whose new threads start on it. A change is saved (`pools.save`, which
/// writes runner.json) as soon as the list is one the runner would take;
/// until then the window says what's missing.
private struct PoolSettings: View {
    @Environment(AppModel.self) private var app
    /// What's shown, which can run ahead of the runner's list while a new
    /// pool has no logins yet.
    @State private var draft: [Pool] = []
    @State private var selected: String?
    @State private var titleDraft = ""

    var body: some View {
        if !app.poolsSupported {
            Form {
                Text(app.connection == .connected ? "This runner is too old for pools. It gets them when it next updates." : "Not connected to the runner.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 140)
        } else {
            form
                .onAppear { reset(to: app.pools) }
                // The runner's list wins, unless Mike is part way through
                // a change it wouldn't take yet.
                .onChange(of: app.pools) { _, pools in
                    if Pools.problem(draft, accounts: app.accounts) == nil { reset(to: pools) }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(draft) { pool in
                    PoolListRow(pool: pool, accounts: app.accounts, selected: pool.id == selected) { choose(pool.id) }
                }
                HStack(spacing: 8) {
                    Button("Add Pool", action: add)
                    Spacer()
                    if let pool = current {
                        Button("Delete \(pool.title)…") { delete(pool) }
                            .disabled(draft.count < 2)
                    }
                }
            } header: {
                Text("Pools")
            } footer: {
                Footnote("A new thread starts on its folder's pool, or else the one you picked last. The pool picks a login with room for each turn and moves the thread when one runs out.")
            }

            if let pool = current {
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $titleDraft)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit(commitTitle)
                    }
                }

                Section {
                    let list = Pools.loginList(pool, accounts: app.accounts)
                    ForEach(list, id: \.account.id) { entry in
                        LoginToggleRow(account: entry.account, accounts: app.accounts, included: entry.included,
                                       canMoveUp: entry.included && pool.accountIds.first != entry.account.id,
                                       canMoveDown: entry.included && pool.accountIds.last != entry.account.id,
                                       toggle: { change(Pools.setting(pool, login: entry.account.id, included: $0)) },
                                       move: { change(Pools.moving(pool, login: entry.account.id, by: $0)) },
                                       drop: { change(Pools.moving(pool, login: $0, onto: entry.account.id)) })
                    }
                } header: {
                    Text("Logins")
                } footer: {
                    Footnote("The order decides which provider a mixed pool tries first. Within one provider, the login with the most room runs the turn.")
                }

                Section {
                    if pool.folders.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pool.folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                var changed = pool
                                changed.folders.removeAll { $0 == folder }
                                change(changed)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .tip("Remove")
                        }
                    }
                    Button("Add Folder…") { addFolders(to: pool) }
                } header: {
                    Text("Folders")
                } footer: {
                    Footnote("A new thread in one of these, or in a folder inside one, starts on \(pool.title).")
                }
            }

            if let problem = Pools.problem(draft, accounts: app.accounts) {
                Section {
                    Label(problem, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } else if let error = app.poolsError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .scrollDisabled(true)
    }

    private var current: Pool? { draft.first { $0.id == selected } ?? draft.first }

    private func reset(to pools: [Pool]) {
        draft = pools
        if selected == nil || !pools.contains(where: { $0.id == selected }) { selected = pools.first?.id }
        titleDraft = current?.title ?? ""
    }

    private func choose(_ id: String) {
        commitTitle()
        selected = id
        titleDraft = current?.title ?? ""
    }

    /// Replaces one pool in the draft, and saves the draft if the runner
    /// would take it.
    private func change(_ pool: Pool) {
        guard let index = draft.firstIndex(where: { $0.id == pool.id }) else { return }
        draft[index] = pool
        save()
    }

    private func save() {
        guard Pools.problem(draft, accounts: app.accounts) == nil else { return }
        let list = draft
        Task { await app.savePools(list) }
    }

    private func commitTitle() {
        guard var pool = current else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != pool.title else { return }
        pool.title = title
        change(pool)
    }

    private func add() {
        commitTitle()
        let pool = Pool(id: Pools.newId(title: "New pool", taken: draft.map(\.id)), title: "New pool", accountIds: [])
        draft.append(pool)
        selected = pool.id
        titleDraft = pool.title
    }

    private func delete(_ pool: Pool) {
        let alert = NSAlert()
        alert.messageText = "Delete \(pool.title)?"
        alert.informativeText = "Threads on it carry on with the login they're on, pinned to it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        draft.removeAll { $0.id == pool.id }
        selected = draft.first?.id
        titleDraft = current?.title ?? ""
        save()
    }

    private func addFolders(to pool: Pool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var changed = pool
        for url in panel.urls {
            let folder = SettingsText.folder(url.path)
            if !changed.folders.contains(folder) { changed.folders.append(folder) }
        }
        change(changed)
    }
}

/// A pool in Settings' list: its name, and its logins and folders in grey.
private struct PoolListRow: View {
    let pool: Pool
    let accounts: [Account]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(pool.title)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(!selected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pool.title + (selected ? ", showing" : ""))
    }

    /// "gangbusters, gmail, cannstudios · ~/dev/convex".
    private var detail: String {
        let logins = pool.accountIds.map { AccountName.login($0, accounts: accounts) }
        var text = logins.isEmpty ? "No logins yet" : logins.joined(separator: ", ")
        if !pool.folders.isEmpty { text += " · " + pool.folders.joined(separator: ", ") }
        return text
    }
}

/// A login in a pool: ticked if it's in, dragged (or moved with its
/// arrows) into order.
private struct LoginToggleRow: View {
    let account: Account
    let accounts: [Account]
    let included: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let toggle: (Bool) -> Void
    let move: (Int) -> Void
    /// Another ticked login dropped here takes this one's place.
    let drop: (String) -> Void

    var body: some View {
        row
            // Ticked logins drag into order; the arrows do the same for
            // anyone who'd rather click.
            .draggable(account.id)
            .dropDestination(for: String.self) { ids, _ in
                guard included, let id = ids.first, id != account.id else { return false }
                drop(id)
                return true
            }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { included }, set: toggle)) {
                Text(AccountName.title(account)) + Text("  " + detail).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .lineLimit(1)
            Spacer()
            if included {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    .tip("Earlier in the order")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                    .tip("Later in the order")
            }
        }
    }

    /// "Claude · Convex work only".
    private var detail: String {
        [ModelPicker.providerTitle(account.provider), account.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
