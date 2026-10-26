import Foundation

/// `runner.status` (docs/protocol.md), the parts the app uses. Read
/// leniently: a field an older runner leaves out is empty, not an error.
public struct RunnerStatus: Sendable, Equatable, Decodable {
    public var version: String
    public var release: String?
    /// Threads starting, running or waiting on Mike.
    public var running: [String]
    public var pendingRestart: PendingRestart?

    public init(version: String = "", release: String? = nil, running: [String] = [], pendingRestart: PendingRestart? = nil) {
        self.version = version
        self.release = release
        self.running = running
        self.pendingRestart = pendingRestart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        release = try? c.decodeIfPresent(String.self, forKey: .release)
        running = ((try? c.decodeIfPresent([String].self, forKey: .running)) ?? nil) ?? []
        pendingRestart = try? c.decodeIfPresent(PendingRestart.self, forKey: .pendingRestart)
    }

    enum CodingKeys: String, CodingKey { case version, release, running, pendingRestart }
}

public struct PendingRestart: Sendable, Equatable, Decodable {
    /// "idle" or "now".
    public var when: String
    public var reason: String?
    public var resumeThreadId: String?
    /// The threads it waits for. Empty means it's happening now.
    public var waitingFor: [String]

    public init(when: String = "idle", reason: String? = nil, resumeThreadId: String? = nil, waitingFor: [String] = []) {
        self.when = when
        self.reason = reason
        self.resumeThreadId = resumeThreadId
        self.waitingFor = waitingFor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = (try? c.decodeIfPresent(String.self, forKey: .when)) ?? "idle"
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        resumeThreadId = try? c.decodeIfPresent(String.self, forKey: .resumeThreadId)
        waitingFor = ((try? c.decodeIfPresent([String].self, forKey: .waitingFor)) ?? nil) ?? []
    }

    enum CodingKeys: String, CodingKey { case when, reason, resumeThreadId, waitingFor }
}

public extension RPCClient {
    func runnerStatus() async throws -> RunnerStatus {
        try await call("runner.status", .object([:]), as: RunnerStatus.self)
    }
}

/// What the app knows about a runner restart (`runner.restart` in
/// docs/protocol.md): one waiting for threads to finish, one under way, or
/// none. The runner only pushes `runner.notice` texts, so those move it
/// along straight away, and `runner.status` (asked after each notice and as
/// threads finish) says which threads it's waiting for.
public struct RunnerRestart: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case none
        /// Waiting for this many threads. `threadIds` is empty until
        /// `runner.status` answers (a notice only has the count).
        case pending(count: Int, threadIds: [String])
        /// Shutting down, or down and about to come back.
        case restarting(since: Date)
    }

    /// What a `runner.notice` says about a restart.
    public enum Notice: Sendable, Equatable {
        case pending(Int)
        case restarting
        case cancelled
    }

    public private(set) var phase: Phase = .none

    /// How long a restart keeps the connection banner quiet. A runner that
    /// hasn't come back by then is down, not restarting, and gets the usual
    /// banner with its Try again button.
    public static let patience: TimeInterval = 90

    public init(phase: Phase = .none) {
        self.phase = phase
    }

    /// The runner's restart notices (`pendingMessage` and the cancel in
    /// runner/src/restart.ts), or nil for any other notice.
    public static func parse(_ message: String) -> Notice? {
        if message.hasPrefix("The runner is restarting") { return .restarting }
        if message.hasPrefix("The pending runner restart was cancelled") { return .cancelled }
        let prefix = "The runner will restart when "
        guard message.hasPrefix(prefix) else { return nil }
        let count = message.dropFirst(prefix.count).prefix { $0.isNumber }
        return .pending(Int(count) ?? 1)
    }

    /// Returns true when the notice was about a restart, so the caller can
    /// ask `runner.status` for the details.
    @discardableResult
    public mutating func notice(_ message: String, now: Date) -> Bool {
        guard let notice = Self.parse(message) else { return false }
        switch notice {
        case .pending(let count):
            // Keep the thread list from the last status if it still fits.
            if case .pending(_, let ids) = phase, ids.count == count {
                phase = .pending(count: count, threadIds: ids)
            } else {
                phase = count == 0 ? .restarting(since: now) : .pending(count: count, threadIds: [])
            }
        case .restarting:
            if case .restarting = phase { break }
            phase = .restarting(since: now)
        case .cancelled:
            phase = .none
        }
        return true
    }

    /// A `runner.status` answer while connected.
    public mutating func status(_ pending: PendingRestart?, now: Date) {
        guard let pending else {
            // Nothing pending any more (it was cancelled). One already under
            // way stays so until the connection drops: a status sent just
            // before the shutdown can't undo it.
            if case .pending = phase { phase = .none }
            return
        }
        if pending.when == "now" || pending.waitingFor.isEmpty {
            if case .restarting = phase { return }
            phase = .restarting(since: now)
        } else if case .restarting = phase {
            return
        } else {
            phase = .pending(count: pending.waitingFor.count, threadIds: pending.waitingFor)
        }
    }

    /// The connection dropped, or an attempt to connect failed. A pending
    /// restart that loses the connection has begun: the "restarting now"
    /// notice can go down with the socket.
    public mutating func disconnected(now: Date) {
        if case .pending = phase { phase = .restarting(since: now) }
    }

    /// Connected again: the restart is over. A new one that's pending comes
    /// back with hello's notice and `runner.status`.
    public mutating func connected() {
        phase = .none
    }

    public var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    /// Under way, and not for so long that the runner looks simply down.
    public func isRestarting(now: Date) -> Bool {
        if case .restarting(let since) = phase { return now.timeIntervalSince(since) < Self.patience }
        return false
    }

    /// The pending restart in the runner's own words.
    public var pendingText: String? {
        guard case .pending(let count, _) = phase else { return nil }
        return count == 1 ? "The runner will restart when 1 thread finishes." : "The runner will restart when \(count) threads finish."
    }

    /// The threads it's waiting for, by title, for the banner's tooltip.
    public func waitingForText(title: (String) -> String?) -> String? {
        guard case .pending(_, let ids) = phase, !ids.isEmpty else { return nil }
        let names = ids.map { id in title(id).flatMap { $0.isEmpty ? nil : $0 } ?? id }
        return "Waiting for " + names.joined(separator: ", ")
    }
}
