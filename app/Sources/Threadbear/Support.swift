import AppKit
import ThreadbearCore
import UserNotifications

/// Local notifications for threads that need Mike while he's elsewhere.
@MainActor
enum Notifier {
    /// UNUserNotificationCenter needs a real app bundle; `swift run` has none.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(thread: ThreadSummary) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = thread.title.isEmpty ? "Threadbear" : thread.title
        if thread.status == .waiting {
            content.body = "Waiting for you to answer."
        } else {
            // What the agent asked for, rather than the last line it wrote.
            if let ask = thread.firstOpenAsk {
                content.body = ask.action
            } else {
                content.body = thread.preview.isEmpty ? "Finished." : PreviewText.plain(thread.preview)
            }
        }
        content.userInfo = ["threadId": thread.id]
        content.threadIdentifier = thread.id
        let request = UNNotificationRequest(identifier: "\(thread.id)-\(thread.lastSeq)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Starts the runner's LaunchAgent with `launchctl kickstart`.
enum RunnerLauncher {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(RunnerConfig.launchdLabel).plist"
    }

    /// Returns a readable failure, or nil when launchctl accepted it.
    static func start() async -> String? {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(RunnerConfig.launchdLabel)"
        if await run(["kickstart", service]) == 0 { return nil }
        // Not loaded yet: load it from its plist, then start it.
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return "The runner isn't installed. Run runner/scripts/install-runner.sh in the threadbear repo."
        }
        _ = await run(["bootstrap", domain, plistPath])
        if await run(["kickstart", service]) == 0 { return nil }
        return "launchctl couldn't start \(RunnerConfig.launchdLabel)."
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}

extension String {
    /// Home folder shown as ~.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
