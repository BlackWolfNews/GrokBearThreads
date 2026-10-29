import AppKit
import SwiftUI
import ThreadbearCore

/// The Librarian's page: what clicking Librarian in the activity bar shows
/// in the detail area, beside the sidebar's queue and recent looks. The
/// bear at its card catalogue, a line on what the librarian is for, what
/// it's doing now and its numbers.
struct LibrarianHome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(32)) {
                VStack(alignment: .leading, spacing: zoomed(20)) {
                    LibrarianPicture(width: zoomed(280))
                    LibrarianAbout(status: app.librarian)
                        .frame(maxWidth: zoomed(620), alignment: .leading)
                }
                if let status = app.librarian {
                    // Three across at most, so the six tiles make even rows.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: zoomed(170)), spacing: zoomed(14), alignment: .top)],
                        alignment: .leading,
                        spacing: zoomed(14)
                    ) {
                        ForEach(LibrarianStats.tiles(status, projects: app.projects, threads: Array(app.threads.values))) { tile in
                            StatTile(tile: tile)
                        }
                    }
                    .frame(maxWidth: zoomed(620), alignment: .leading)
                    LibrarianSettings(status: status)
                        .frame(maxWidth: zoomed(620), alignment: .leading)
                }
            }
            .frame(maxWidth: zoomed(1000), alignment: .leading)
            .padding(.horizontal, zoomed(32))
            .padding(.top, zoomed(28))
            .padding(.bottom, zoomed(48))
            .frame(maxWidth: .infinity)
        }
    }
}

/// The bear at its card catalogue. Nothing when the picture didn't ship
/// (a build that left the resource bundle out), rather than a gap.
private struct LibrarianPicture: View {
    let width: CGFloat

    var body: some View {
        if let image = Art.librarian {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .accessibilityLabel("The librarian bear, filing a card in a card catalogue")
        }
    }
}

/// The name, a line on what it does (more behind the ⓘ), and what it's
/// doing now.
private struct LibrarianAbout: View {
    @Environment(AppModel.self) private var app
    let status: LibrarianStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(12)) {
            HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
                Text("Librarian")
                    .font(.system(size: zoomed(24), weight: .semibold))
                InfoTip(Self.more)
            }
            Text("Reads your threads as they go and keeps your projects tidy: it files each thread in a project, writes down where the project's up to, and renames threads that have wandered off from their title.")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                    Circle()
                        .fill(status.state == .working ? Color(nsColor: .controlAccentColor) : Color(nsColor: Theme.faintText))
                        .frame(width: zoomed(7), height: zoomed(7))
                    Text(LibrarianText.state(status))
                        .font(.system(size: TypeScale.label))
                        .lineLimit(1)
                }
                .padding(.top, zoomed(4))
            }
        }
    }

    static let more = "It takes a look after a thread's first message and when a turn ends, then catches up at most every 20 minutes while the thread keeps going. A catch-up after only a quick reply is skipped without asking the model. Each look is one call to the small model in Settings › Models. A thread you take out of a project is never put back in it."
}

/// What can be changed about the librarian, here rather than only in
/// Settings: whether it's looking at all, which pool's Claude logins it
/// runs on and the OpenRouter budget behind them. The last two are the
/// runner's small-model settings, which titles share, so a change here is
/// a change in Settings › Models too (their tips say so).
private struct LibrarianSettings: View {
    @Environment(AppModel.self) private var app
    let status: LibrarianStatus
    @State private var budgetDraft: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(12)) {
            Text("Settings")
                .font(.system(size: zoomed(17), weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: zoomed(16), verticalSpacing: zoomed(12)) {
                GridRow {
                    Text("Look at threads")
                        .foregroundStyle(.secondary)
                    Toggle("Look at threads", isOn: Binding(get: { !status.paused }, set: { app.setLibrarianPaused(!$0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tip(status.paused ? "Paused: what's queued waits. Turn it on to carry on" : "Turn it off to pause; what's queued waits")
                }
                if let settings = app.runnerSettings {
                    if settings.models.poolSupported {
                        GridRow {
                            Text("Runs on")
                                .foregroundStyle(.secondary)
                            Picker("Runs on", selection: Binding(get: { settings.models.pool }, set: { app.updateSettings(SettingsUpdate(pool: .some($0))) })) {
                                ForEach(app.claudePools) { pool in
                                    Text(pool.title).tag(Optional(pool.id))
                                }
                                // A pool deleted since it was picked, so the
                                // picker still says what's set.
                                if let id = settings.models.pool, !app.claudePools.contains(where: { $0.id == id }) {
                                    Text("\(id), which has no Claude login").tag(Optional(id))
                                }
                                Divider()
                                Text("OpenRouter only").tag(String?.none)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .tip("Which pool's Claude logins it uses, the one with the most room. Titles use the same pool (Settings › Models)")
                        }
                    }
                    GridRow {
                        Text("OpenRouter budget")
                            .foregroundStyle(.secondary)
                        HStack(spacing: zoomed(4)) {
                            Text("$").foregroundStyle(.secondary)
                            TextField("OpenRouter budget", value: $budgetDraft, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: zoomed(60))
                                .onSubmit { saveBudget(settings) }
                            Text("a day").foregroundStyle(.secondary)
                        }
                        .tip("Most to spend on OpenRouter in a day, for when the pool's out of room, shared with titles. Return saves it. $0 stops OpenRouter calls")
                    }
                    .onAppear { budgetDraft = settings.models.dailyBudgetUsd }
                    .onChange(of: settings.models.dailyBudgetUsd) { _, new in budgetDraft = new }
                }
            }
            .font(.system(size: TypeScale.label))
            Button("More in Settings…") { app.openModelSettings() }
                .controlSize(.small)
                .tip("The OpenRouter key and private folders, whose threads are never sent anywhere")
        }
        .padding(.top, zoomed(8))
    }

    private func saveBudget(_ settings: RunnerSettings) {
        guard budgetDraft >= 0, budgetDraft != settings.models.dailyBudgetUsd else { return }
        app.updateSettings(SettingsUpdate(dailyBudgetUsd: budgetDraft))
    }
}

/// One number and what it counts, with more in its tooltip.
private struct StatTile: View {
    let tile: LibrarianStats.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(4)) {
            Text(tile.value)
                .font(.system(size: zoomed(22), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(tile.label)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, zoomed(14))
        .padding(.vertical, zoomed(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: zoomed(10), style: .continuous))
        .tip(tile.help)
        .accessibilityElement(children: .combine)
    }
}

/// The page's numbers, from the status the runner sends and what the app
/// already knows about projects and threads.
enum LibrarianStats {
    struct Tile: Identifiable, Equatable {
        var id: String { label }
        let value: String
        let label: String
        let help: String
    }

    static func tiles(_ status: LibrarianStatus, projects: [Project], threads: [ThreadSummary]) -> [Tile] {
        let made = projects.filter { $0.createdBy == .librarian && !$0.archived }.count
        let filed = threads.filter { $0.archivedAt == nil && $0.projects.contains { $0.by == .librarian } }.count
        return [
            Tile(value: "\(status.looksToday)", label: "Looks today",
                 help: "Threads it has looked at since midnight"),
            Tile(value: "\(status.skippedToday)", label: "Skipped today",
                 help: "Catch-ups after only a quick reply, skipped without asking the model"),
            Tile(value: LibrarianText.tokens(status.tokensToday), label: "Tokens today",
                 help: "What today's looks sent and got back"),
            // Money actually spent: pool looks would otherwise read as a bill.
            Tile(value: LibrarianText.spent(status), label: "Spent today",
                 help: ["What OpenRouter charged today", LibrarianText.apiValue(status)].compactMap { $0 }.joined(separator: ". ")),
            Tile(value: "\(made)", label: made == 1 ? "Project it made" : "Projects it made",
                 help: "Projects the librarian started that aren't archived"),
            Tile(value: "\(filed)", label: filed == 1 ? "Thread it filed" : "Threads it filed",
                 help: "Open threads the librarian put in a project"),
        ]
    }
}

/// Pictures that ship in the app's resource bundle (Package.swift,
/// Resources/Art). Found by hand rather than through Bundle.module, which
/// stops the app when the bundle isn't there (CodeHighlighter does the
/// same): build-app.sh copies it into Contents/Resources, and `swift run`
/// and `swift test` have it beside the binary.
enum Art {
    @MainActor static let librarian: NSImage? = image("librarian")

    private static let bundle: Bundle? = {
        let name = "Threadbear_Threadbear.bundle"
        return [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0?.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap(Bundle.init(url:))
    }()

    private static func image(_ name: String) -> NSImage? {
        guard let url = bundle?.url(forResource: name, withExtension: "png", subdirectory: "Art") else { return nil }
        return NSImage(contentsOf: url)
    }
}
