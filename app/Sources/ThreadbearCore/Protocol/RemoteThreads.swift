import Foundation

/// Other runners' threads (docs/protocol.md, "Other runners' threads"):
/// what `remoteThreads.list` answers and `remoteThreads.updated` sends. The
/// runner reads them from the backend; the app lists them beside its own
/// runner's and, to open one, connects to that thread's runner itself
/// (`RemoteClients`). Runners never talk to each other.
public struct RemoteThreads: Sendable, Hashable, Decodable {
    public var runners: [RemoteRunner]
    public var threads: [RemoteThread]

    public init(runners: [RemoteRunner] = [], threads: [RemoteThread] = []) {
        self.runners = runners
        self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runners = c.lossyArray(RemoteRunner.self, forKey: .runners)
        threads = c.lossyArray(RemoteThread.self, forKey: .threads)
    }

    enum CodingKeys: String, CodingKey { case runners, threads }

    public func runner(_ id: String) -> RemoteRunner? { runners.first { $0.id == id } }

    /// The threads as sidebar summaries, each marked with its runner.
    public var summaries: [ThreadSummary] { threads.map(\.summary) }
}

/// Another runner, as the backend knows it, and how to reach it from here.
public struct RemoteRunner: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    /// "bruce": its Mac's hostname by default.
    public var name: String
    /// An SF Symbol for its Mac ("macmini"), as `RunnerInfo.icon`.
    public var icon: String?
    /// Heard from in the last 3 minutes.
    public var online: Bool
    public var lastSeenAt: Date?
    /// Its `sync.rpcUrl`: a `wss://…/rpc` on the tailnet.
    public var rpcUrl: URL?
    /// Where this Mac keeps that runner's token, once it's been copied in.
    /// Nil means its threads can be listed but not opened.
    public var tokenFile: String?

    public init(id: String, name: String, icon: String? = nil, online: Bool = true, lastSeenAt: Date? = nil, rpcUrl: URL? = nil, tokenFile: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.rpcUrl = rpcUrl
        self.tokenFile = tokenFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        func text(_ key: CodingKeys) -> String? { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
        name = text(.name) ?? id
        icon = text(.icon)
        online = ((try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? nil) ?? false
        lastSeenAt = text(.lastSeenAt).flatMap(ISO8601.parse)
        rpcUrl = text(.rpcUrl).flatMap(URL.init(string:))
        tokenFile = text(.tokenFile)
    }

    enum CodingKeys: String, CodingKey { case id, name, icon, online, lastSeenAt, rpcUrl, tokenFile }
}

/// One row of another runner's sidebar table: what a sidebar row shows,
/// not the whole summary that runner keeps.
public struct RemoteThread: Sendable, Hashable, Decodable {
    public var runnerId: String
    public var threadId: String
    public var title: String
    public var cwd: String
    public var accountId: String
    public var provider: String
    public var model: String?
    public var status: ThreadStatus
    public var needsYou: Bool
    public var unread: Bool
    public var preview: String
    public var createdAt: Date
    public var lastActivityAt: Date
    public var snoozedUntil: Date?
    public var archivedAt: Date?

    public init(runnerId: String, threadId: String, title: String = "", cwd: String = "", accountId: String = "", provider: String = "claude",
                model: String? = nil, status: ThreadStatus = .idle, needsYou: Bool = false, unread: Bool = false, preview: String = "",
                createdAt: Date = Date(), lastActivityAt: Date = Date(), snoozedUntil: Date? = nil, archivedAt: Date? = nil) {
        self.runnerId = runnerId
        self.threadId = threadId
        self.title = title
        self.cwd = cwd
        self.accountId = accountId
        self.provider = provider
        self.model = model
        self.status = status
        self.needsYou = needsYou
        self.unread = unread
        self.preview = preview
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.snoozedUntil = snoozedUntil
        self.archivedAt = archivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runnerId = try c.decode(String.self, forKey: .runnerId)
        threadId = try c.decode(String.self, forKey: .threadId)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        title = text(.title) ?? ""
        cwd = text(.cwd) ?? ""
        accountId = text(.accountId) ?? ""
        provider = text(.provider).flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        model = text(.model).flatMap { $0.isEmpty ? nil : $0 }
        status = ((try? c.decodeIfPresent(ThreadStatus.self, forKey: .status)) ?? nil) ?? .idle
        needsYou = flag(.needsYou)
        unread = flag(.unread)
        preview = text(.preview) ?? ""
        createdAt = text(.createdAt).flatMap(ISO8601.parse) ?? Date(timeIntervalSince1970: 0)
        lastActivityAt = text(.lastActivityAt).flatMap(ISO8601.parse) ?? createdAt
        snoozedUntil = text(.snoozedUntil).flatMap(ISO8601.parse)
        archivedAt = text(.archivedAt).flatMap(ISO8601.parse)
    }

    enum CodingKeys: String, CodingKey {
        case runnerId, threadId, title, cwd, accountId, provider, model, status, needsYou, unread, preview
        case createdAt, lastActivityAt, snoozedUntil, archivedAt
    }

    /// As a summary the sidebar's rows and sections take like a local one.
    /// The table has no seqs, so an unread one gets 1 and 0, which is all
    /// the rows look at; opening the thread fetches the real summary from
    /// its runner.
    public var summary: ThreadSummary {
        var summary = ThreadSummary(
            id: threadId, title: title, cwd: cwd, accountId: accountId, provider: provider, model: model,
            status: status, needsYou: needsYou, createdAt: createdAt, updatedAt: lastActivityAt, lastActivityAt: lastActivityAt,
            snoozedUntil: snoozedUntil, archivedAt: archivedAt, preview: preview,
            lastSeq: unread ? 1 : 0, lastSeenSeq: 0
        )
        // Hibernating until that runner restarts is kept as a date in the
        // year 9999 (`threads.update` with "restart").
        if let snoozedUntil, snoozedUntil > Self.restartFarOff { summary.snoozedUntilRestart = true }
        summary.runnerId = runnerId
        return summary
    }

    static let restartFarOff = Date(timeIntervalSince1970: 200_000_000_000)
}

/// Where a thread's requests go: this Mac's own runner, or the runner it
/// lives on.
public enum ThreadRoute: Sendable, Equatable {
    case local
    case remote(RemoteRunner)
    /// Another runner's thread whose runner isn't listed any more.
    case unknownRunner(String)

    public static func of(_ thread: ThreadSummary?, runners: [RemoteRunner]) -> ThreadRoute {
        guard let runnerId = thread?.runnerId else { return .local }
        guard let runner = runners.first(where: { $0.id == runnerId }) else { return .unknownRunner(runnerId) }
        return .remote(runner)
    }
}

/// Why another runner's thread can't be opened from this Mac, in words for
/// the place its transcript would be.
public struct RemoteUnreachable: Error, Sendable, Equatable, LocalizedError {
    public enum Reason: Sendable, Equatable {
        /// No token for it on this Mac (`tokenFile` absent or unreadable).
        case noToken
        /// It hasn't told the backend its `sync.rpcUrl`.
        case noAddress
        /// Its runner isn't in the list any more.
        case unknownRunner
        /// It turned the token down.
        case refused
        /// It didn't answer, or the connection failed.
        case failed(String)
    }

    public var runnerId: String
    public var runnerName: String
    public var online: Bool
    public var reason: Reason

    public init(runnerId: String, runnerName: String, online: Bool, reason: Reason) {
        self.runnerId = runnerId
        self.runnerName = runnerName
        self.online = online
        self.reason = reason
    }

    public init(_ runner: RemoteRunner, _ reason: Reason) {
        self.init(runnerId: runner.id, runnerName: runner.name, online: runner.online, reason: reason)
    }

    public var headline: String { "Can't reach \(runnerName) from this Mac." }

    public var detail: String {
        switch reason {
        case .noToken: return "Its runner token isn't on this Mac yet (secrets/runners/\(runnerId).token)."
        case .noAddress: return "It hasn't said how to reach it yet (sync.rpcUrl in its runner.json)."
        case .unknownRunner: return "Its runner isn't listed any more."
        case .refused: return "It didn't accept the token this Mac has for it."
        case .failed(let why):
            // Offline or not, the usual cause is a Mac asleep or Tailscale off.
            return online ? "It didn't answer (\(why))." : "It's offline, or Tailscale is off on one of the Macs."
        }
    }

    public var errorDescription: String? { detail }

    static func from(_ error: Error, runner: RemoteRunner) -> RemoteUnreachable {
        if let unreachable = error as? RemoteUnreachable { return unreachable }
        switch error as? RPCError {
        case .unauthorized?: return RemoteUnreachable(runner, .refused)
        case .connectFailed(let why)?: return RemoteUnreachable(runner, .failed(why))
        case .timeout?: return RemoteUnreachable(runner, .failed("it took too long"))
        case .disconnected?: return RemoteUnreachable(runner, .failed("the connection closed"))
        default: return RemoteUnreachable(runner, .failed(error.localizedDescription))
        }
    }
}

/// The app's connections to other runners: one per runner, opened when one
/// of its threads is opened and closed when none is, with the same
/// transport and protocol as the app's own runner's.
@MainActor
public final class RemoteClients {
    public typealias MakeTransport = @Sendable (URL, String) -> RPCTransport

    /// Every notification from a runner's connection, with its id.
    public var onNotification: ((_ runnerId: String, RPCNotification) -> Void)?
    /// A connection came up (after its hello).
    public var onConnected: ((_ runnerId: String, RPCClient) -> Void)?
    /// A connection ended: closed here or dropped.
    public var onClosed: ((_ runnerId: String) -> Void)?

    private struct Entry {
        var client: RPCClient
        var url: URL
        var token: String
    }

    private let version: String
    private let makeTransport: MakeTransport
    private let readToken: (String) -> String?
    private var open: [String: Entry] = [:]
    private var connecting: [String: Task<RPCClient, Error>] = [:]

    public init(version: String, makeTransport: @escaping MakeTransport = { WebSocketTransport(url: $0, token: $1) },
                readToken: @escaping (String) -> String? = RemoteClients.readTokenFile) {
        self.version = version
        self.makeTransport = makeTransport
        self.readToken = readToken
    }

    public nonisolated static func readTokenFile(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The runner's connection, if it's up.
    public func connected(_ runnerId: String) -> RPCClient? {
        guard let entry = open[runnerId], !entry.client.isClosed else { return nil }
        return entry.client
    }

    public var connectedRunners: Set<String> { Set(open.keys.filter { connected($0) != nil }) }

    /// The client a thread's requests go to, without connecting: this
    /// Mac's runner's for its own threads, the thread's runner's while
    /// that's connected, nil otherwise.
    public func client(for route: ThreadRoute, local: RPCClient?) -> RPCClient? {
        switch route {
        case .local: return local
        case .remote(let runner): return connected(runner.id)
        case .unknownRunner: return nil
        }
    }

    /// The runner's connection, opening it if need be. Throws
    /// `RemoteUnreachable` saying why it can't.
    public func client(for runner: RemoteRunner) async throws -> RPCClient {
        if let client = connected(runner.id) { return client }
        if let pending = connecting[runner.id] { return try await pending.value }
        guard let url = runner.rpcUrl else { throw RemoteUnreachable(runner, .noAddress) }
        guard let file = runner.tokenFile, let token = readToken(file) else { throw RemoteUnreachable(runner, .noToken) }
        let makeTransport = makeTransport
        let version = version
        let task = Task { () throws -> RPCClient in
            let client = RPCClient(transport: makeTransport(url, token))
            do {
                try await client.start()
                _ = try await client.hello(version: version)
            } catch {
                client.close()
                throw RemoteUnreachable.from(error, runner: runner)
            }
            return client
        }
        connecting[runner.id] = task
        let client: RPCClient
        do {
            client = try await task.value
        } catch {
            connecting[runner.id] = nil
            throw error
        }
        connecting[runner.id] = nil
        adopt(client, runnerId: runner.id, url: url, token: token)
        return client
    }

    private func adopt(_ client: RPCClient, runnerId: String, url: URL, token: String) {
        open[runnerId]?.client.close()
        open[runnerId] = Entry(client: client, url: url, token: token)
        Task { [weak self] in
            for await notification in client.notifications {
                self?.onNotification?(runnerId, notification)
            }
            // Dropped rather than closed here: closing removes it first.
            guard let self, self.open[runnerId]?.client === client else { return }
            self.open[runnerId] = nil
            self.onClosed?(runnerId)
        }
        onConnected?(runnerId, client)
    }

    public func close(_ runnerId: String) {
        guard let entry = open.removeValue(forKey: runnerId) else { return }
        entry.client.close()
        onClosed?(runnerId)
    }

    public func closeAll() {
        for id in Array(open.keys) { close(id) }
    }
}
