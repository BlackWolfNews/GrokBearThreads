import AppKit
import SwiftUI
import ThreadbareCore
import UserNotifications

@main
struct ThreadbareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    init() {
        UserDefaults.standard.register(defaults: [
            // AppKit treats command-line arguments it can't pair up as files
            // to open, and then skips opening the window.
            // `--perf-run --stream-seconds 5` leaves "5" over.
            "NSTreatUnknownArgumentsAsOpen": "NO",
            // After a kill (or a crash) AppKit "restores" a saved state with
            // no window in it and SwiftUI then opens nothing. There's no
            // window state worth restoring here; the frame autosaves anyway.
            "ApplePersistenceIgnoreState": "YES",
        ])
    }

    var body: some Scene {
        Window("Threadbare", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { LaunchClock.windowShown() }
        }
        .defaultSize(width: 1180, height: 800)
        // Always open the window at launch. With restoration on, a saved
        // state with no window (closing the window quits the app, and so
        // does a kill) made the next launch show nothing at all. The frame
        // is still remembered through the window's autosave.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { app.newThread() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Thread") {
                Button(app.selectedThread?.isArchived == true ? "Unarchive" : "Archive") { app.toggleArchive() }
                    .keyboardShortcut("e")
                    .disabled(app.selection == nil)
                Menu("Snooze") {
                    // Titles follow app.now (so the menu rebuilds as time
                    // passes); the date is worked out when the item is chosen.
                    ForEach(Snooze.presets(now: app.now)) { preset in
                        Button(preset.title) { app.snooze(until: Snooze.date(for: preset.id, now: Date())) }
                    }
                    Divider()
                    Button("Pick a time…") {
                        if let id = app.selection { SnoozePicker.show(threadId: id, app: app) }
                    }
                }
                .disabled(app.selection == nil)
                Button("Stop") { app.interrupt() }
                    .keyboardShortcut(".")
                    .disabled(app.selectedThread?.status.isBusy != true)
                Divider()
                Button("Copy Transcript as Markdown") {
                    if let id = app.selection { app.session(for: id).copyTranscript() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(app.selection == nil)
                Divider()
                Button("Show Inbox") { app.sidebarMode = .inbox }
                Button("Show Snoozed") { app.sidebarMode = .snoozed }
                Button("Show Archive") { app.showArchive() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let app = AppModel.shared
            let arguments = CommandLine.arguments
            let perf = arguments.contains("--perf-run")
            let screenshots = arguments.contains("--screenshots")
            // Scripted runs (perf, screenshots, a test driving the app) post
            // no banners on the screen of whoever is using the Mac.
            #if DEBUG
            let scripted = perf || screenshots || arguments.contains("--automation")
            #else
            let scripted = perf || screenshots
            #endif
            app.notificationsEnabled = !scripted
            if !scripted { Notifier.setUp(delegate: self) }
            app.onThreadsLoaded = { LaunchClock.threadsLoaded() }
            app.start()
            if perf { PerfRunner.start(app: app) }
            if screenshots { ScreenshotRunner.start(app: app) }
            #if DEBUG
            Automation.startIfAsked(app: app)
            #endif
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.appBecameActive() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        await MainActor.run {
            NSApp.activate()
            if let threadId {
                AppModel.shared.sidebarMode = .inbox
                AppModel.shared.select(threadId)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Launch timing for the perf report: process start to window and to a
/// loaded thread list.
@MainActor
enum LaunchClock {
    static var windowMs: Double?
    static var threadsMs: Double?

    static func windowShown() {
        if windowMs == nil { windowMs = sinceLaunch() }
    }

    static func threadsLoaded() {
        if threadsMs == nil { threadsMs = sinceLaunch() }
    }

    static func sinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}
