import Foundation

/// What the rail's updates icon and its popover say about the app's own
/// update (AppUpdater: a build of main staged, building, or failed) and the
/// runner's (protocol "Runner updates"). Plain sentences, one per thing
/// going on; the view adds the buttons.
public enum UpdatesText {
    /// The app's side, as AppUpdater knows it.
    public struct AppSide: Sendable, Equatable {
        public var running: String?   // short commit of the running build
        public var staged: String?    // short commit waiting to be swapped in
        public var building: Bool
        public var failed: Bool

        public init(running: String? = nil, staged: String? = nil, building: Bool = false, failed: Bool = false) {
            self.running = running
            self.staged = staged
            self.building = building
            self.failed = failed
        }

        public var isPending: Bool { staged != nil || building }
    }

    /// Whether the icon shows at all: something on its way, or something
    /// that went wrong.
    public static func shown(app: AppSide, runner: RunnerUpdates?) -> Bool {
        app.isPending || app.failed || runner?.isPending == true || runner?.failed == true
    }

    /// Whether it wants Mike: a failed build, or a launch.mjs only he can
    /// install. Everything else happens by itself.
    public static func needsYou(app: AppSide, runner: RunnerUpdates?) -> Bool {
        app.failed || runner?.failed == true || runner?.launcherChanged == true
    }

    /// The icon's tooltip.
    public static func tooltip(app: AppSide, runner: RunnerUpdates?) -> String {
        let appPart = app.isPending || app.failed
        let runnerPart = runner?.isPending == true || runner?.failed == true
        switch (appPart, runnerPart) {
        case (true, true): return "Updates for the app and the runner"
        case (true, false): return "An app update"
        case (false, true): return "A runner update"
        default: return "Updates"
        }
    }

    public static func appLine(_ a: AppSide) -> String {
        if let staged = a.staged { return "The app's next version (\(staged)) is ready. It switches in when you're not using the app, or now." }
        if a.building { return "Building the app from main." }
        if a.failed { return "The app's last build from main failed. The log says why." }
        return a.running.map { "The app is up to date (\($0))." } ?? "The app is up to date."
    }

    /// The runner's own build: building, built and starting, or failed.
    public static func buildLine(_ u: RunnerUpdates) -> String? {
        let at = u.commit.map { " at \($0)" } ?? ""
        let what = u.subject.map { ": \($0)" } ?? ""
        switch u.state {
        case "building": return "Building the runner from main\(at)\(what)."
        case "waiting": return "The runner from main\(at) is built and starting."
        case "failed": return "The runner couldn't update to main\(at)\(u.reason.map { ": \($0)" } ?? ".")"
        default: return nil
        }
    }

    /// Threads still finishing on an old runner; the view links each one
    /// under it.
    public static func oldRunnersLine(_ u: RunnerUpdates) -> String? {
        let threads = u.oldRunners.reduce(0) { $0 + $1.threads.count }
        if threads == 0 { return nil }
        return threads == 1
            ? "1 thread is finishing its turn on the previous version. It moves to the new one when the turn ends."
            : "\(threads) threads are finishing their turns on the previous version. Each moves to the new one when its turn ends."
    }

    /// A launch.mjs only install-runner.sh puts in place; the view shows
    /// the command under it.
    public static func launcherLine(_ u: RunnerUpdates) -> String? {
        u.launcherChanged ? "launch.mjs has changed on main. It only updates when you run this, once nothing is busy:" : nil
    }

    /// Every runner line in order, or the one that says there's nothing.
    public static func runnerLines(_ u: RunnerUpdates?) -> [String] {
        guard let u else { return ["This runner doesn't say how its updates are going."] }
        let out = [buildLine(u), oldRunnersLine(u), launcherLine(u)].compactMap { $0 }
        return out.isEmpty ? ["The runner is up to date."] : out
    }

    /// The command for a changed launch.mjs.
    public static func installCommand(checkout: String?) -> String {
        let root = checkout.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/dev/me/threadbare"
        return "\(root)/runner/scripts/install-runner.sh"
    }
}
