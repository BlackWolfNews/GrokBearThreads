import Foundation
import os

/// The app's own log: the connection coming and going, RPC errors, runner
/// notices and, in a scripted debug run, the automation commands. It always
/// goes to the unified log (subsystem com.mikerosoft.threadbare, category
/// app). A debug build launched with `--automation` also appends each line
/// to a file next to the automation log, which `Tools/dev-app.sh log`
/// tails, so an agent driving the app can see why something didn't happen.
enum AppLog {
    private static let logger = Logger(subsystem: "com.mikerosoft.threadbare", category: "app")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var file: FileHandle?
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts copying lines to `url` (a new, empty file).
    static func writeFile(to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        lock.withLock { file = try? FileHandle(forWritingTo: url) }
    }

    static func write(_ category: String, _ message: String) {
        logger.log("\(category, privacy: .public): \(message, privacy: .public)")
        lock.withLock {
            guard let file else { return }
            let line = "\(clock.string(from: Date())) \(category) \(message)\n"
            file.seekToEndOfFile()
            file.write(Data(line.utf8))
        }
    }
}
