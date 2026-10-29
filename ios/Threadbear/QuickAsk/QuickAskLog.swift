import Foundation
import OSLog

/// Quick ask's log: each line goes to the system log (Console.app, `log stream --predicate
/// 'subsystem == "com.mikecann.threadbear"'`) and is appended straight away to
/// Library/Caches/quickask.log, so a hang on a phone can be read off it afterwards with
/// `devicectl device copy from`, even if the app's killed. (Reading the system log back from the
/// app only returns notices and errors, and `log collect` from a phone needs root.) The file stays
/// on the phone and is cut back once it's large. Never log the archive server's token.
nonisolated enum Log {
    static let app = QuickAskLogger(category: "quickask")
    static let audio = QuickAskLogger(category: "quickask-audio")
    static let speech = QuickAskLogger(category: "quickask-speech")
    static let net = QuickAskLogger(category: "quickask-net")
    static let timing = QuickAskLogger(category: "quickask-timing")
}

nonisolated struct QuickAskLogger: Sendable {
    let category: String
    private var logger: Logger { Logger(subsystem: "com.mikecann.threadbear", category: category) }

    init(category: String) { self.category = category }

    func info(_ message: QuickAskLogMessage) {
        logger.info("\(message.text, privacy: .public)")
        QuickAskLogFile.append("\(category) \(message.text)")
    }

    func error(_ message: QuickAskLogMessage) {
        logger.error("\(message.text, privacy: .public)")
        QuickAskLogFile.append("\(category) ERROR \(message.text)")
    }
}

/// A log line written the way the call sites were for `os.Logger` (`\(x, privacy: .public)`), so
/// they didn't need changing. Everything's kept: the file never leaves the phone.
nonisolated struct QuickAskLogMessage: ExpressibleByStringInterpolation, Sendable {
    enum Privacy { case `public`, `private` }

    struct Interpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .private) { text += "\(value)" }
    }

    let text: String
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: Interpolation) { text = stringInterpolation.text }
}

/// Wall-clock seconds, the one clock every timing uses (so it lines up with the process start time).
nonisolated enum Stopwatch {
    static var now: Double { Date().timeIntervalSince1970 }
}

/// For handing an object that's only ever used safely (by the API's own rules) across a closure
/// boundary Swift can't see into, like a recognition request that's documented as thread-safe.
nonisolated final class UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// True the first time `claim()` is called, false after. For callbacks that fire many times when
/// only the first one matters, from whatever thread.
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Library/Caches/quickask.log: every quick ask log line, time-stamped, appended as it happens.
nonisolated enum QuickAskLogFile {
    private static let queue = DispatchQueue(label: "com.mikecann.threadbear.quickask.logfile", qos: .utility)
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("quickask.log")
    private static let limit = 1_000_000

    static func append(_ line: String) {
        let stamp = Date()
        queue.async {
            guard let url else { return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds, .withColonSeparatorInTime, .withDashSeparatorInDate]
            let data = Data("\(formatter.string(from: stamp)) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > UInt64(limit) {
                    // Keep the newest half.
                    try? handle.close()
                    if let old = try? Data(contentsOf: url) {
                        try? (old.suffix(limit / 2) + data).write(to: url)
                    }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
