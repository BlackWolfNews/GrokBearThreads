import Foundation

/// An in-memory backend for the simulator, screenshots and previews, so the
/// app can be built and looked at without a runner or a deployment. It
/// plays the runner's part too: a sent message starts a short turn that
/// ends with a canned reply.
public final class FakeBackend: Backend, @unchecked Sendable {
    private let lock = NSLock()
    private var threadsById: [String: PhoneThread]
    private var messagesById: [String: [PhoneMessage]]
    private var runnerList: [PhoneRunner]
    private var commands: [String: CommandStatus] = [:]
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    /// How long a fake turn takes. Zero in tests.
    private let turnDelay: Duration

    public init(now: Date = .now, turnDelay: Duration = .seconds(2), runnerOnline: Bool = true) {
        let sample = Self.sample(now: now)
        threadsById = Dictionary(uniqueKeysWithValues: sample.threads.map { ($0.threadId, $0) })
        messagesById = sample.messages
        runnerList = [PhoneRunner(runnerId: "m5", name: "MacBook Pro", version: "0.1.0",
                                  lastSeenAt: runnerOnline ? now : now.addingTimeInterval(-3 * 3600))]
        self.turnDelay = turnDelay
    }

    // MARK: Live reads

    private func watch<T: Sendable>(_ read: @escaping @Sendable () -> T) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let push: @Sendable () -> Void = { continuation.yield(read()) }
            lock.withLock { listeners[id] = push }
            push()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
            }
        }
    }

    private func changed() {
        let all = lock.withLock { Array(listeners.values) }
        for push in all { push() }
    }

    private func mutate(_ body: (FakeBackend) -> Void) {
        lock.withLock { body(self) }
        changed()
    }

    public func me() async throws -> PhoneIdentity {
        // Always a current backend, so the demo never says the Mac needs updating.
        PhoneIdentity(name: "iphone", expiresAt: Date.now.addingTimeInterval(90 * 86_400),
                      apiVersion: BackendCompatibility.currentAPIVersion)
    }

    public func runners() -> AsyncThrowingStream<[PhoneRunner], Error> {
        watch { [unowned self] in lock.withLock { runnerList } }
    }

    public func projects() -> AsyncThrowingStream<[PhoneProject], Error> {
        watch { Self.sampleProjects }
    }

    public func threads(_ view: ThreadsView) -> AsyncThrowingStream<[PhoneThread], Error> {
        watch { [unowned self] in
            let all = lock.withLock { Array(threadsById.values) }
            let now = Date.now
            return all.filter { t in
                switch view {
                case .den: t.archivedAt != nil
                case .hibernating: t.archivedAt == nil && InboxSections.isSnoozed(t, now: now)
                case .inbox: t.archivedAt == nil && !InboxSections.isSnoozed(t, now: now)
                }
            }.sorted { $0.lastActivityAt > $1.lastActivityAt }
        }
    }

    public func thread(_ threadId: String) -> AsyncThrowingStream<ThreadDetail?, Error> {
        watch { [unowned self] in
            lock.withLock {
                threadsById[threadId].map { ThreadDetail(thread: $0, messages: messagesById[threadId] ?? []) }
            }
        }
    }

    public func messages(_ threadId: String, limit: Int) -> AsyncThrowingStream<MessagePage, Error> {
        watch { [unowned self] in
            let all = lock.withLock { messagesById[threadId] ?? [] }
            return MessagePage(messages: Array(all.suffix(limit)), hasMore: all.count > limit)
        }
    }

    public func command(_ commandId: String) -> AsyncThrowingStream<CommandStatus?, Error> {
        watch { [unowned self] in lock.withLock { commands[commandId] } }
    }

    public func connectionStates() -> AsyncStream<Bool> {
        AsyncStream { $0.yield(true) }
    }

    // MARK: Commands

    private func newCommand(threadId: String? = nil) -> String {
        let id = "cmd_" + UUID().uuidString.prefix(8)
        lock.withLock { commands[id] = CommandStatus(state: .done, threadId: threadId) }
        return id
    }

    private func append(_ threadId: String, role: PhoneMessage.Role, text: String, origin: String? = nil) {
        var list = messagesById[threadId] ?? []
        list.append(PhoneMessage(seq: (list.last?.seq ?? 0) + 1, role: role, text: text, origin: origin, at: .now))
        messagesById[threadId] = list
    }

    private func runTurn(_ threadId: String, reply: String) {
        let delay = turnDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.mutate { s in
                s.append(threadId, role: .assistant, text: reply)
                s.threadsById[threadId]?.status = .idle
                s.threadsById[threadId]?.working = nil
                s.threadsById[threadId]?.needsYou = true
                s.threadsById[threadId]?.unread = true
                s.threadsById[threadId]?.preview = reply
                s.threadsById[threadId]?.lastActivityAt = .now
            }
        }
    }

    public func send(threadId: String, text: String) async throws -> String {
        mutate { s in
            s.append(threadId, role: .user, text: text, origin: "phone")
            s.threadsById[threadId]?.status = .running
            s.threadsById[threadId]?.working = "Bear with me"
            s.threadsById[threadId]?.needsYou = false
            s.threadsById[threadId]?.unread = false
            s.threadsById[threadId]?.lastActivityAt = .now
        }
        runTurn(threadId, reply: "Done. I've made that change and the checks pass.")
        return newCommand()
    }

    public func respond(threadId: String, approvalId: String, decision: ApprovalOption) async throws -> String {
        mutate { s in
            s.threadsById[threadId]?.pendingApproval = nil
            s.threadsById[threadId]?.status = decision == .deny ? .idle : .running
            s.threadsById[threadId]?.working = decision == .deny ? nil : "Running the command"
        }
        if decision != .deny { runTurn(threadId, reply: "That ran fine. Everything's green.") }
        return newCommand()
    }

    public func answer(threadId: String, approvalId: String, answers: [String: String], summary: String) async throws -> String {
        mutate { s in
            s.append(threadId, role: .user, text: summary, origin: "phone")
            s.threadsById[threadId]?.pendingApproval = nil
            s.threadsById[threadId]?.status = .running
            s.threadsById[threadId]?.working = "Bear with me"
        }
        runTurn(threadId, reply: "Thanks, going with that.")
        return newCommand()
    }

    public func update(threadId: String, change: ThreadChange) async throws -> String {
        mutate { s in
            switch change {
            case let .snooze(until): s.threadsById[threadId]?.snoozedUntil = until
            case .snoozeUntilRestart: s.threadsById[threadId]?.snoozedUntilRestart = true
            case .wake:
                s.threadsById[threadId]?.snoozedUntil = nil
                s.threadsById[threadId]?.snoozedUntilRestart = nil
            case .archive: s.threadsById[threadId]?.archivedAt = .now
            case .unarchive: s.threadsById[threadId]?.archivedAt = nil
            case .markSeen:
                s.threadsById[threadId]?.unread = false
                s.threadsById[threadId]?.needsYou = false
            case let .rename(title): s.threadsById[threadId]?.title = title
            }
        }
        return newCommand()
    }

    public func create(text: String, runnerId: String?, cwd: String?) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let title = String(text.prefix(48))
        mutate { s in
            s.threadsById[id] = PhoneThread(threadId: id, title: title, cwd: cwd ?? "~/code/misc", status: .running,
                                            lastActivityAt: .now, working: "Bear with me")
            s.append(id, role: .user, text: text, origin: "phone")
        }
        runTurn(id, reply: "On it. Here's what I found.")
        return newCommand(threadId: id)
    }

    public func setNotifications(apnsToken: String, notify: NotifyMode) async throws {}

    public func loadEarlier(threadId: String, beforeSeq: Int) async throws -> String {
        let delay = turnDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay / 4)
            self?.mutate { s in
                let earliest = Int(s.threadsById[threadId]?.earliestSeq ?? 1)
                let seqs = Array(max(earliest, beforeSeq - 50)..<beforeSeq)
                let older = seqs.map { seq in
                    PhoneMessage(seq: seq, role: seq % 2 == 0 ? .assistant : .user,
                                 text: seq % 2 == 0 ? "An earlier reply, number \(seq)." : "An earlier ask, number \(seq).",
                                 at: Date.now.addingTimeInterval(Double(seq - beforeSeq) * 300))
                }
                s.messagesById[threadId] = older + (s.messagesById[threadId] ?? [])
            }
        }
        return newCommand()
    }

    public func registerDevice(apnsToken: String, environment: String, pushKey: String?) async throws {}

    // MARK: Sample data

    /// Made-up threads for the demo (App Review taps "Look around with
    /// sample threads"), the simulator and the screenshots. Nothing in here
    /// is from a real thread, and no real project or app is named:
    /// FakeBackendTests checks for the names that used to be here.
    /// The projects the sample threads are in, with symbols for icons (a
    /// picture would need a URL to fetch; the demo has no backend).
    public static let sampleProjects = [
        PhoneProject(id: "p_garden", title: "Garden planner", icon: PhoneProjectIcon(symbol: "leaf", by: "librarian")),
        PhoneProject(id: "p_site", title: "Website", icon: PhoneProjectIcon(symbol: "globe", by: "librarian")),
    ]

    static func sample(now: Date) -> (threads: [PhoneThread], messages: [String: [PhoneMessage]]) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let garden = [ProjectRef(id: "p_garden", title: "Garden planner")]
        let site = [ProjectRef(id: "p_site", title: "Website")]
        let threads = [
            PhoneThread(threadId: "a1", title: "Release 1.2 of the garden app", cwd: "~/code/garden-planner", status: .waiting,
                        needsYou: true, preview: "Everything passes. Ready to tag 1.2.0 and push it.",
                        lastActivityAt: ago(4), projects: garden,
                        pendingApproval: .approval(id: "ap1", name: "Bash", title: "Run a command",
                                                   options: [.allow, .allowAlways, .deny],
                                                   inputSummary: "git tag v1.2.0 && git push origin v1.2.0")),
            PhoneThread(threadId: "a2", title: "Where should the settings live?", cwd: "~/code/garden-planner",
                        status: .waiting, needsYou: true, preview: "Two ways to do this.", lastActivityAt: ago(12),
                        projects: garden,
                        pendingApproval: .question(id: "q1", questions: [
                            Question(question: "Where should each person's settings live?", header: "Settings", options: [
                                .init(label: "In the database", description: "Follows them to a new phone"),
                                .init(label: "On the phone", description: "Simplest, nothing to sync"),
                            ]),
                        ])),
            PhoneThread(threadId: "a3", title: "Date picker on small screens", cwd: "~/code/website",
                        needsYou: true, unread: true,
                        preview: "Fixed in 4700e57. The picker fits on the smallest iPhone now.",
                        lastActivityAt: ago(25), costUsd: 1.84, projects: site, earliestSeq: 1),
            PhoneThread(threadId: "a4", title: "Tidy up old feature flags", cwd: "~/code/api",
                        preview: "Removed six flags nothing reads any more.", lastActivityAt: ago(190)),
            PhoneThread(threadId: "a5", title: "Search box for the docs", cwd: "~/code/website", status: .running,
                        preview: "Adding the index.", lastActivityAt: ago(1), projects: site,
                        working: "Running npm test"),
            PhoneThread(threadId: "a6", title: "Upgrade the router", cwd: "~/code/website",
                        preview: "Picked the next three pages to move.", lastActivityAt: ago(60 * 20),
                        snoozedUntil: now.addingTimeInterval(3600 * 14)),
            PhoneThread(threadId: "a7", title: "Rename the settings screen", cwd: "~/code/garden-planner",
                        preview: "Done.", lastActivityAt: ago(60 * 30), archivedAt: ago(60 * 26)),
        ]
        let messages: [String: [PhoneMessage]] = [
            "a1": [
                PhoneMessage(seq: 1, role: .user, text: "Get 1.2 ready to release", at: ago(30)),
                PhoneMessage(seq: 2, role: .tool, text: "Read CHANGELOG.md", toolKind: "read", at: ago(29)),
                PhoneMessage(seq: 3, role: .tool, text: "Bump the version to 1.2.0", toolKind: "command", at: ago(28)),
                PhoneMessage(seq: 4, role: .tool, text: "Edited CHANGELOG.md", toolKind: "edit", at: ago(27)),
                PhoneMessage(seq: 5, role: .tool, text: "Run the unit tests", toolKind: "command", at: ago(12)),
                PhoneMessage(seq: 6, role: .assistant, text: "Bumped the version to **1.2.0** and wrote up the changelog. All 214 tests pass.\n\nReady to tag 1.2.0 and push it.", at: ago(4)),
            ],
            "a2": [
                PhoneMessage(seq: 1, role: .user, text: "Let people pick metric or imperial in settings", at: ago(15)),
            ],
            "a3": [
                PhoneMessage(seq: 120, role: .user, text: "The date picker gets cut off on small phones, can you fix it?", at: ago(50)),
                PhoneMessage(seq: 121, role: .assistant, text: "Fixed in `4700e57`. The picker fits on the smallest iPhone now, and I checked it in the simulator at three sizes.", at: ago(25)),
            ],
            "a5": [
                PhoneMessage(seq: 1, role: .user, text: "Okay, let's go with it.", at: ago(8)),
            ],
            "a6": [
                PhoneMessage(seq: 1, role: .user, text: "Review: Router upgrade order (0f3c2a9e-5b1d-4e7a-9c64-2d8b1f0a7e35)\n\nPicked B. B: docs pages first.\n\nNotes on B (B: docs pages first): Leave the search page till last.", at: ago(60 * 21)),
                PhoneMessage(seq: 2, role: .assistant, text: "Going with the docs pages first, search last. Picked the next three pages to move.", at: ago(60 * 20)),
            ],
        ]
        return (threads, messages)
    }
}
