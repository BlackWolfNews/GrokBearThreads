import AppKit
import Observation

/// What a bundle was built from. `build-app.sh` writes it to
/// Contents/Resources/build.json.
struct BuildInfo: Codable, Equatable {
    var commit: String
    var short: String
    /// The tree hash of app/ at that commit (`git rev-parse <commit>:app`).
    /// Only a change under app/ changes what runs, so this, not the commit,
    /// says whether a build would be any different.
    var appTree: String
    var builtAt: String
    /// The checkout it was built from, whose main the updater follows.
    var checkout: String
    var configuration: String

    static func read(bundle: URL) -> BuildInfo? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/build.json")) else { return nil }
        return try? JSONDecoder().decode(BuildInfo.self, from: data)
    }
}

/// The file moves and decisions of the self-update, with no app state, so
/// the tests can run them on temp folders.
enum AppUpdate {
    enum Action: Equatable {
        case nothing
        /// Main's app/ differs from what's running and nothing staged or
        /// being built matches it.
        case build(appTree: String)
        /// What's staged no longer matches main, and main is what's
        /// running already: drop it.
        case dropStaged
    }

    static func decide(mainTree: String, running: BuildInfo, staged: BuildInfo?, building: String?, failed: String?) -> Action {
        if mainTree == running.appTree {
            return staged != nil ? .dropStaged : .nothing
        }
        if staged?.appTree == mainTree || building == mainTree || failed == mainTree { return .nothing }
        return .build(appTree: mainTree)
    }

    /// Puts the staged bundle in the installed one's place, in two renames
    /// so the app is gone for an instant and never half there. The old
    /// bundle (the running one, when this is done on quit) goes to `old`,
    /// to be deleted at the next launch.
    static func swap(install: URL, next: URL, old: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: old.path) { try files.removeItem(at: old) }
        if files.fileExists(atPath: install.path) { try files.moveItem(at: install, to: old) }
        try files.moveItem(at: next, to: install)
    }

    /// Swaps a staged bundle in if it would change anything, and returns
    /// what was swapped in. A staged bundle that matches what's running (a
    /// build that finished after the same commit was installed another way)
    /// is dropped. Leftovers of an earlier swap are deleted first.
    @discardableResult
    static func applyStaged(install: URL, next: URL, old: URL, running: BuildInfo?) -> BuildInfo? {
        let files = FileManager.default
        if files.fileExists(atPath: old.path) { try? files.removeItem(at: old) }
        guard files.fileExists(atPath: next.path) else { return nil }
        guard let staged = BuildInfo.read(bundle: next), staged.appTree != running?.appTree else {
            try? files.removeItem(at: next)
            return nil
        }
        do {
            try swap(install: install, next: next, old: old)
            AppLog.write("update", "swapped in \(staged.short) (built \(staged.builtAt))")
            return staged
        } catch {
            AppLog.write("update", "couldn't swap \(next.lastPathComponent) in: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether to restart on its own to take a staged build: nothing typed
    /// would be lost, and Mike isn't in the app (another app is in front, or
    /// he hasn't touched this one for a while). Running threads don't hold
    /// it up: the runner owns the turns and the app replays what it missed
    /// when it reconnects.
    static func shouldAutoRestart(staged: Bool, loaded: Bool, hasDrafts: Bool, active: Bool, idleFor: TimeInterval) -> Bool {
        guard staged, loaded, !hasDrafts else { return false }
        return !active || idleFor >= AppUpdater.autoRestartIdleTime
    }

    /// Opens `bundle` again once this process has exited: a shell that
    /// waits for the pid, then `open`. Children of a GUI app outlive it.
    /// `inBackground` opens it without bringing it in front (`open -g`),
    /// for a restart Mike didn't ask for while he's in another app.
    static func relaunchAfterExit(_ bundle: URL, inBackground: Bool = false) {
        let open = inBackground ? "/usr/bin/open -g" : "/usr/bin/open"
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; \(open) \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.write("update", "couldn't start the relaunch: \(error.localizedDescription)")
        }
    }
}

/// The installed app keeps itself current with the checkout it was built
/// from. Every few minutes it reads main's tree hash for app/ there, and
/// when that differs from what's running it builds that commit (release,
/// in the background, from its own clone and build folder under
/// ~/Library/Caches/Threadbare/update, so nothing an agent does in the
/// checkout is built or disturbed) into ~/Applications/.Threadbare.app.next.
/// Quitting swaps the staged bundle in, so the next launch is the new app;
/// a launch that finds one staged (the app was killed rather than quit)
/// swaps it in and relaunches. "Restart to Update" in the app menu does it
/// now, and the app does it by itself once nothing typed would be lost
/// and Mike isn't using it (see `shouldAutoRestart`),
/// reopening the thread he had open. Only the installed app does any of this: a debug app from
/// Tools/dev-app.sh, a perf run or a screenshot run has another bundle
/// path or a scripted flag, and a bundle with no build.json (built before
/// this existed) stays as it is until install.sh or restart.sh is run once.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()
    static let checkInterval: TimeInterval = 5 * 60
    /// After launch, once the app has connected and settled.
    static let firstCheckDelay: TimeInterval = 20
    /// How often a staged build is weighed against what's going on.
    nonisolated static let autoRestartInterval: TimeInterval = 30
    /// With the app in front, this long without a key or a click counts as
    /// not using it.
    nonisolated static let autoRestartIdleTime: TimeInterval = 5 * 60
    static let logPath = NSHomeDirectory() + "/Library/Logs/threadbare-update.log"
    /// Where the app was (the thread and sidebar list) when it restarted
    /// itself, put back once the threads have loaded.
    static let restoreKey = "updateRestore"

    nonisolated static var installDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADBARE_APP_DIR"] ?? NSHomeDirectory() + "/Applications/Threadbare.app")
    }
    nonisolated static var nextDir: URL { installDir.deletingLastPathComponent().appendingPathComponent(".Threadbare.app.next") }
    nonisolated static var oldDir: URL { installDir.deletingLastPathComponent().appendingPathComponent(".Threadbare.app.old") }

    /// True for the installed app in an ordinary launch.
    nonisolated static var isInstalledApp: Bool {
        let arguments = CommandLine.arguments
        let scripted = arguments.contains("--perf-run") || arguments.contains("--screenshots") || arguments.contains("--automation")
        guard !scripted, !arguments.contains("--no-update") else { return false }
        return Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == installDir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A staged update found at launch: swapped in, with a relaunch on the
    /// way. The caller exits. Before anything else in the app starts.
    nonisolated static func applyStagedAtLaunch() -> Bool {
        guard isInstalledApp else { return false }
        let running = BuildInfo.read(bundle: Bundle.main.bundleURL)
        guard AppUpdate.applyStaged(install: installDir, next: nextDir, old: oldDir, running: running) != nil else { return false }
        AppUpdate.relaunchAfterExit(installDir)
        return true
    }

    /// The bundle waiting to be swapped in, for the app menu.
    private(set) var staged: BuildInfo?
    /// The running bundle's build, or nil when there's nothing to follow.
    private(set) var running: BuildInfo?
    /// Why updates are off, for the log.
    private(set) var disabledReason: String?
    @ObservationIgnored private var building: String?
    @ObservationIgnored private var failed: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var restartTimer: Timer?
    @ObservationIgnored private var build: Process?
    @ObservationIgnored private var lastInput = Date()
    @ObservationIgnored private var inputMonitor: Any?
    @ObservationIgnored private var restarting = false

    var enabled: Bool { running != nil && disabledReason == nil }

    func start() {
        guard Self.isInstalledApp else {
            disabledReason = "not the installed app"
            return
        }
        guard let info = BuildInfo.read(bundle: Bundle.main.bundleURL), !info.appTree.isEmpty else {
            disabledReason = "no build.json in the bundle; run app/install.sh (or restart.sh) once to get a build that updates itself"
            AppLog.write("update", disabledReason!)
            return
        }
        guard FileManager.default.fileExists(atPath: info.checkout + "/.git") else {
            disabledReason = "the checkout it was built from, \(info.checkout), is gone"
            AppLog.write("update", disabledReason!)
            return
        }
        guard Bundle.main.url(forResource: "stage-update", withExtension: "sh") != nil else {
            disabledReason = "no stage-update.sh in the bundle"
            AppLog.write("update", disabledReason!)
            return
        }
        running = info
        staged = BuildInfo.read(bundle: Self.nextDir)
        AppLog.write("update", "running \(info.short) (\(info.configuration)) from \(info.checkout); following main" + (staged.map { "; \($0.short) is staged" } ?? ""))
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelay))
            self?.check()
        }
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRestartInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.considerAutoRestart(app: AppModel.shared) }
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.lastInput = Date()
            return event
        }
    }

    /// Restarts into the staged build when that wouldn't interrupt anything.
    func considerAutoRestart(app: AppModel) {
        guard let staged, !restarting else { return }
        // An open schedule editor counts as something typed: a restart
        // would throw away what's in it.
        let hasDrafts = app.drafts.values.contains { !$0.text.isEmpty || !$0.images.isEmpty } || app.scheduleEditor != nil
        let active = NSApp.isActive
        guard AppUpdate.shouldAutoRestart(staged: true, loaded: app.threadsLoaded && app.connection == .connected,
                                          hasDrafts: hasDrafts, active: active, idleFor: Date().timeIntervalSince(lastInput)) else { return }
        AppLog.write("update", "restarting into \(staged.short): nothing typed, " + (active ? "no input for a while" : "the app isn't in front"))
        restart(app: app, inBackground: !active)
    }

    private func restart(app: AppModel, inBackground: Bool) {
        restarting = true
        Self.saveRestore(selection: app.selection, mode: app.sidebarMode)
        AppUpdate.relaunchAfterExit(Self.installDir, inBackground: inBackground)
        NSApp.terminate(nil)
    }

    private static func saveRestore(selection: String?, mode: SidebarMode) {
        let modeName = switch mode {
        case .inbox: "inbox"
        case .snoozed: "snoozed"
        case .archive: "archive"
        case .scheduled: "scheduled"
        }
        UserDefaults.standard.set(["selection": selection ?? "", "mode": modeName], forKey: restoreKey)
    }

    /// After a restart the app made itself: back to the thread and list
    /// that were open. Called once the threads have loaded.
    static func restoreAfterRestart(app: AppModel) {
        guard let saved = UserDefaults.standard.dictionary(forKey: restoreKey) as? [String: String] else { return }
        UserDefaults.standard.removeObject(forKey: restoreKey)
        switch saved["mode"] {
        case "snoozed": app.sidebarMode = .snoozed
        case "archive": app.showArchive()
        case "scheduled": app.showSchedules()
        default: app.sidebarMode = .inbox
        }
        if let id = saved["selection"], !id.isEmpty, app.threads[id] != nil { app.select(id) }
    }

    /// Reads main's app/ tree in the checkout and starts a build if it's new.
    func check() {
        guard let running, build == nil else { return }
        Task { @MainActor in
            let result = await Self.run("/usr/bin/git", ["-C", running.checkout, "rev-parse", "--verify", "-q", "refs/heads/main:app"])
            guard result.status == 0 else {
                AppLog.write("update", "git rev-parse main:app failed in \(running.checkout): \(result.output)")
                return
            }
            let mainTree = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // What's staged may have been swapped in or dropped by hand.
            staged = BuildInfo.read(bundle: Self.nextDir)
            switch AppUpdate.decide(mainTree: mainTree, running: running, staged: staged, building: building, failed: failed) {
            case .nothing:
                break
            case .dropStaged:
                try? FileManager.default.removeItem(at: Self.nextDir)
                staged = nil
                AppLog.write("update", "dropped the staged build; main is what's running again")
            case .build(let appTree):
                startBuild(appTree: appTree, checkout: running.checkout)
            }
        }
    }

    private func startBuild(appTree: String, checkout: String) {
        guard let script = Bundle.main.url(forResource: "stage-update", withExtension: "sh") else { return }
        let process = Process()
        // The build takes every core for a minute or two; it yields to
        // whatever Mike and the agents are doing.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "15", "/bin/bash", script.path, checkout, "--next", Self.nextDir.path]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let log = Self.openLog()
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.buildFinished(appTree: appTree, status: status) }
        }
        do {
            try process.run()
            build = process
            building = appTree
            Self.log("Building main's app/ \(appTree.prefix(12)) (running \(running?.short ?? "?"))")
            AppLog.write("update", "building main (app/ \(appTree.prefix(12))); log: \(Self.logPath)")
        } catch {
            AppLog.write("update", "couldn't start the build: \(error.localizedDescription)")
        }
    }

    private func buildFinished(appTree: String, status: Int32) {
        build = nil
        building = nil
        if status == 0, let info = BuildInfo.read(bundle: Self.nextDir) {
            staged = info
            failed = nil
            AppLog.write("update", "\(info.short) is staged; it's swapped in when the app quits or is relaunched")
        } else {
            // Not tried again until main moves on or the app is relaunched.
            failed = appTree
            AppLog.write("update", "the build failed (exit \(status)); see \(Self.logPath)")
        }
    }

    /// On quit: the staged bundle takes the installed one's place, so the
    /// next launch is the new app. The running binary stays in `.old`
    /// until then.
    func applyAtQuit() {
        guard enabled else { return }
        build?.terminate()
        AppUpdate.applyStaged(install: Self.installDir, next: Self.nextDir, old: Self.oldDir, running: running)
    }

    /// "Restart to Update": quit (which swaps the staged bundle in) and
    /// open the app again.
    func restartToUpdate() {
        guard staged != nil else { return }
        restart(app: AppModel.shared, inBackground: false)
    }

    // MARK: Helpers

    private static func openLog() -> FileHandle {
        let files = FileManager.default
        if !files.fileExists(atPath: logPath) { files.createFile(atPath: logPath, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    private static func log(_ line: String) {
        let handle = openLog()
        handle.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        try? handle.close()
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
