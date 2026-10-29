import AppKit
import ThreadbearCore

/// Other runners' threads (docs/protocol.md, "Other runners' threads").
/// Their sidebar rows come from this Mac's runner, which reads them from
/// the backend, and sit in `threads` beside this Mac's own, marked with
/// `runnerId`, so the sidebar, the header and the composer take them as
/// they are. Opening one connects to its own runner, and every request
/// about it goes there (`client(for:)`). The connection closes again a
/// minute after none of that runner's threads is on screen.
extension AppModel {
    // MARK: The list

    /// The list after hello; `remoteThreads.updated` replaces it from then on.
    func loadRemoteThreads() {
        guard let client else { return }
        Task {
            do {
                receive(remote: try await client.remoteThreads())
            } catch {
                AppLog.write("rpc", "remoteThreads.list failed: \(error.localizedDescription)")
            }
        }
    }

    func receive(remote: RemoteThreads) {
        remoteIndex = remote
        if remoteRunners != remote.runners { remoteRunners = remote.runners }
        applyRemoteIndex()
    }

    /// Puts the table's rows in `threads`, except where that runner's own
    /// connection has given a fuller summary, and lets go of rows that have
    /// gone from it (deleted there).
    func applyRemoteIndex() {
        var next = threads
        var listed: Set<String> = []
        for summary in remoteIndex.summaries {
            // Never in place of one of this Mac's own.
            if let existing = next[summary.id], !existing.isRemote { continue }
            listed.insert(summary.id)
            if liveRemote.contains(summary.id), next[summary.id] != nil { continue }
            next[summary.id] = summary
        }
        let gone = next.values.filter { $0.isRemote && !listed.contains($0.id) && !liveRemote.contains($0.id) }.map(\.id)
        if next != threads { threads = next }
        for id in gone { forget(id) }
    }

    func isRemote(_ threadId: String) -> Bool { threads[threadId]?.isRemote == true }

    func route(_ threadId: String) -> ThreadRoute { ThreadRoute.of(threads[threadId], runners: remoteRunners) }

    /// The logins a thread's pickers offer: its runner's. This Mac's for its
    /// own threads and a new one; another runner's once its connection has
    /// said hello, nil until then (the composer shows just that Mac's name).
    func logins(for thread: ThreadSummary?) -> RunnerLogins? {
        guard let runnerId = thread?.runnerId else { return RunnerLogins(accounts: accounts, pools: pools, defaults: defaults) }
        return remoteLogins[runnerId]
    }

    /// The runner one of another runner's threads lives on, if it's listed.
    func remoteRunner(of thread: ThreadSummary) -> RemoteRunner? {
        guard let id = thread.runnerId else { return nil }
        return remoteRunners.first { $0.id == id }
    }

    /// "bruce", for another runner's thread; nil for this Mac's own.
    func runnerName(of thread: ThreadSummary) -> String? {
        guard thread.isRemote else { return nil }
        return remoteRunner(of: thread)?.name ?? "another Mac"
    }

    /// The SF Symbol for the runner a thread lives on, as the schedule
    /// editor draws runners.
    func runnerIcon(of thread: ThreadSummary) -> String { RunnerIcon.symbol(remoteRunner(of: thread)?.icon) }

    /// "On bruce", and whether it's offline, for a remote row's tooltip.
    func runnerPlace(of thread: ThreadSummary) -> String? {
        guard let name = runnerName(of: thread) else { return nil }
        return remoteRunner(of: thread)?.online == false ? "On \(name), offline" : "On \(name)"
    }

    // MARK: Routing

    /// Where a thread's requests go, without connecting: this Mac's runner
    /// for its own threads (and with no thread), the thread's runner while
    /// it's connected, else nil.
    func client(for threadId: String?) -> RPCClient? {
        guard let threadId else { return client }
        return remoteClients.client(for: route(threadId), local: client)
    }

    /// The same, connecting to the thread's runner if need be. Throws
    /// `RemoteUnreachable` when it can't be reached from this Mac.
    func openClient(for threadId: String) async throws -> RPCClient {
        switch route(threadId) {
        case .local:
            guard let client else { throw RPCError.disconnected(nil) }
            return client
        case .remote(let runner):
            return try await remoteClients.client(for: runner)
        case .unknownRunner(let id):
            throw RemoteUnreachable(runnerId: id, runnerName: "its runner", online: false, reason: .unknownRunner)
        }
    }

    /// What the banner says when a send can't go.
    func notConnectedText(_ threadId: String?, _ what: String) -> String {
        if let thread = threadId.flatMap({ threads[$0] }), let name = runnerName(of: thread) {
            return "Not connected to \(name), so \(what). It's still in the box."
        }
        return "Not connected to the runner, so \(what). It's still in the box."
    }

    /// Opens the thread's runner's connection again for a transcript that's
    /// still loaded; its subscription comes back with it (`remoteConnected`).
    /// One that can't says so where the transcript was.
    func reconnectRemote(for threadId: String) {
        Task {
            do {
                _ = try await openClient(for: threadId)
            } catch {
                loadedSession(threadId)?.markUnreachable(error)
            }
        }
    }

    /// In the main panel or a panel of its own.
    func isOnScreen(_ threadId: String) -> Bool {
        selection == threadId || dock.layout.contains(WindowDock.threadPanel(threadId))
    }

    /// Closes connections to runners none of whose threads is on screen, a
    /// minute after the last one went, so going back and forth between
    /// threads doesn't connect each time.
    func tidyRemoteClients() {
        guard !remoteClients.connectedRunners.isEmpty else { return }
        remoteTidy?.cancel()
        remoteTidy = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            let showing = Set(self.threads.values.filter { self.isOnScreen($0.id) }.compactMap(\.runnerId))
            for id in self.remoteClients.connectedRunners where !showing.contains(id) {
                AppLog.write("connection", "closing the connection to \(self.remoteName(id)): none of its threads is open")
                self.remoteClients.close(id)
            }
        }
    }

    // MARK: Connections

    func wireRemoteClients() {
        remoteClients.onNotification = { [weak self] runnerId, notification in self?.receiveRemote(notification, from: runnerId) }
        remoteClients.onConnected = { [weak self] runnerId, client in self?.remoteConnected(runnerId, client) }
        remoteClients.onClosed = { [weak self] runnerId in self?.remoteClosed(runnerId) }
    }

    private func remoteName(_ runnerId: String) -> String { remoteRunners.first { $0.id == runnerId }?.name ?? runnerId }

    /// What that runner says about its own threads reaches them as this
    /// runner's does about its; the rest (its accounts, schedules,
    /// settings) is that Mac's business.
    private func receiveRemote(_ notification: RPCNotification, from runnerId: String) {
        switch notification {
        case .threadUpdated(var thread):
            // Never in place of one of this Mac's own.
            if let existing = threads[thread.id], existing.runnerId != runnerId { return }
            thread.runnerId = runnerId
            liveRemote.insert(thread.id)
            receive(thread)
        case .threadEvent(let threadId, let event):
            guard threads[threadId]?.runnerId == runnerId else { return }
            loadedSession(threadId)?.receive(event)
        case .threadDeleted(let threadId):
            guard threads[threadId]?.runnerId == runnerId else { return }
            liveRemote.remove(threadId)
            forget(threadId)
        // Its own logins, for the pickers on its threads.
        case .accountsUpdated(let list):
            remoteLogins[runnerId]?.accounts = list
        case .poolsUpdated(let list):
            remoteLogins[runnerId]?.pools = list
        default:
            break
        }
    }

    private func remoteConnected(_ runnerId: String, _ client: RPCClient) {
        AppLog.write("connection", "connected to \(remoteName(runnerId))")
        Task {
            // Its logins (accounts with their models, pools, defaults) fill
            // the composer's pickers on its threads; its accounts.updated
            // and pools.updated keep them current.
            if let hello = try? await client.hello(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"), remoteClients.connected(runnerId) === client {
                remoteLogins[runnerId] = RunnerLogins(hello: hello)
            }
            // Its own summaries are fuller than the table's rows (seqs, the
            // open card, the permission), and its thread.updated keeps
            // them fresh while it's connected.
            if let list = try? await client.listThreads(include: [.inbox, .snoozed]), remoteClients.connected(runnerId) === client {
                var next = threads
                for var thread in list {
                    if let existing = next[thread.id], existing.runnerId != runnerId { continue }
                    thread.runnerId = runnerId
                    liveRemote.insert(thread.id)
                    next[thread.id] = thread
                }
                if next != threads { threads = next }
            }
            // A transcript still loaded from before picks up where it was.
            for session in openSessions where session.state == .loaded && threads[session.threadId]?.runnerId == runnerId {
                await session.subscribe()
            }
        }
    }

    private func remoteClosed(_ runnerId: String) {
        AppLog.write("connection", "the connection to \(remoteName(runnerId)) ended")
        for thread in threads.values where thread.runnerId == runnerId { liveRemote.remove(thread.id) }
        for session in openSessions where threads[session.threadId]?.runnerId == runnerId {
            guard isOnScreen(session.threadId) else {
                // Read afresh when it's next opened.
                dropSession(session.threadId)
                continue
            }
            session.connectionLost()
            // A Mac waking up or a blip on the tailnet: one more go, then
            // it says it can't reach it.
            Task { [weak self, weak session] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let session, self.loadedSession(session.threadId) === session, !session.subscribed else { return }
                self.reconnectRemote(for: session.threadId)
            }
        }
        applyRemoteIndex()
    }
}
