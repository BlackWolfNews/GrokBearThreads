import Foundation
import os

/// `log stream --predicate 'subsystem == "com.mikecann.threadbear" AND category BEGINSWITH "quickask"'`
/// (or Console.app) shows these. Never log the archive server's token.
nonisolated enum Log {
    static let app = Logger(subsystem: "com.mikecann.threadbear", category: "quickask")
    static let audio = Logger(subsystem: "com.mikecann.threadbear", category: "quickask-audio")
    static let speech = Logger(subsystem: "com.mikecann.threadbear", category: "quickask-speech")
    static let net = Logger(subsystem: "com.mikecann.threadbear", category: "quickask-net")
    static let timing = Logger(subsystem: "com.mikecann.threadbear", category: "quickask-timing")
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
