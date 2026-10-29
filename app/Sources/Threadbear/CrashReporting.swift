import Foundation
#if !DEBUG
import Sentry
#endif

/// Crash and error reports to Sentry (project `threadbear`, tag
/// component: mac), from the installed app only. Agents run debug builds,
/// tests, perf runs and screenshot runs of this app all day, and an agent
/// watcher opens a thread for anything that reaches Sentry, so only a
/// release build running as ~/Applications/Threadbear.app in an ordinary
/// launch reports (`AppUpdater.isInstalledApp`): never a Debug build
/// (dev-app.sh, swift test), never a release one somewhere else
/// (perf-run.sh) or a scripted one. THREADBEAR_SENTRY=off turns it off.
///
/// Crashes and errors only: no tracing, sessions, app-hang reports,
/// breadcrumbs or PII.
enum CrashReporting {
    /// A public client key (it ships in every Sentry client); fine to commit.
    static let dsn = "https://c69460318b1f938fd1703c6578a059f6@o4508736647266304.ingest.us.sentry.io/4512336956293120"

    static func start() {
        #if !DEBUG
        guard AppUpdater.isInstalledApp, ProcessInfo.processInfo.environment["THREADBEAR_SENTRY"] != "off" else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let short = BuildInfo.read(bundle: Bundle.main.bundleURL)?.short ?? "unknown"
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.releaseName = "threadbear-mac@\(version)+\(short)"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoSessionTracking = false
            // A busy main thread (a long transcript rendering) isn't a crash.
            options.enableAppHangTracking = false
            // AppKit swallows uncaught NSExceptions unless asked.
            options.enableUncaughtNSExceptionReporting = true
            // Breadcrumbs could carry a thread's text or a path.
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.maxBreadcrumbs = 0
        }
        SentrySDK.configureScope { scope in
            scope.setTag(value: "mac", key: "component")
        }
        AppLog.write("sentry", "crash reporting on (\(version)+\(short))")
        #endif
    }
}
