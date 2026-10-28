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
        runnerList = [PhoneRunner(runnerId: "m5", name: "M5", version: "0.1.0",
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
        PhoneIdentity(name: "iphone", expiresAt: Date.now.addingTimeInterval(90 * 86_400))
    }

    public func runners() -> AsyncThrowingStream<[PhoneRunner], Error> {
        watch { [unowned self] in lock.withLock { runnerList } }
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
            s.threadsById[id] = PhoneThread(threadId: id, title: title, cwd: cwd ?? "~/dev/me/misc", status: .running,
                                            lastActivityAt: .now, working: "Bear with me")
            s.append(id, role: .user, text: text, origin: "phone")
        }
        runTurn(id, reply: "On it. Here's what I found.")
        return newCommand(threadId: id)
    }

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

    public func registerDevice(apnsToken: String, environment: String) async throws {}

    // MARK: Sample data

    static func sample(now: Date) -> (threads: [PhoneThread], messages: [String: [PhoneMessage]]) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let threadbear = [ProjectRef(id: "p_2adc13b8", title: "Threadbear")]
        let poddle = [ProjectRef(id: "p_poddle", title: "Poddle")]
        let threads = [
            PhoneThread(threadId: "a1", title: "Ship Poddle 1.0.1", cwd: "~/dev/me/poddle", status: .waiting,
                        needsYou: true, preview: "Ready to submit build 2610270253 for review.",
                        lastActivityAt: ago(4), projects: poddle,
                        pendingApproval: .approval(id: "ap1", name: "Bash", title: "Run a command",
                                                   options: [.allow, .allowAlways, .deny],
                                                   inputSummary: "node scripts/appstore-submit.mjs --version 1.0.1")),
            PhoneThread(threadId: "a2", title: "Pick a database for the shed viewer", cwd: "~/dev/me/dads-shed",
                        status: .waiting, needsYou: true, preview: "Two ways to do this.", lastActivityAt: ago(12),
                        pendingApproval: .question(id: "q1", questions: [
                            Question(question: "Where should the measurements live?", header: "Storage", options: [
                                .init(label: "Convex", description: "Live, editable from the phone"),
                                .init(label: "A JSON file", description: "Simplest, rebuild to change"),
                            ]),
                        ])),
            PhoneThread(threadId: "a3", title: "Sidebar rows: two lines again", cwd: "~/dev/me/threadbear",
                        needsYou: true, unread: true,
                        preview: "Merged as 4700e57. Each row has a project tile and the status on the right.",
                        lastActivityAt: ago(25), costUsd: 3.12, projects: threadbear, earliestSeq: 1),
            PhoneThread(threadId: "a4", title: "Backblaze exclusions on Bruce", cwd: "~/dev/me/misc",
                        preview: "All applied. Restart needs your sudo on the Mac.", lastActivityAt: ago(190)),
            PhoneThread(threadId: "a5", title: "Convex mirror for the phone", cwd: "~/dev/me/threadbear", status: .running,
                        preview: "Writing the schema.", lastActivityAt: ago(1), projects: threadbear,
                        working: "Running npm test"),
            PhoneThread(threadId: "a6", title: "Juice audit follow-ups", cwd: "~/dev/me/misc",
                        preview: "Picked the next three.", lastActivityAt: ago(60 * 20),
                        snoozedUntil: now.addingTimeInterval(3600 * 14)),
            PhoneThread(threadId: "a7", title: "Window-only screenshots", cwd: "~/dev/me/misc",
                        preview: "Done.", lastActivityAt: ago(60 * 30), archivedAt: ago(60 * 26)),
        ]
        let messages: [String: [PhoneMessage]] = [
            "a1": [
                PhoneMessage(seq: 1, role: .user, text: "Get 1.0.1 into review", at: ago(30)),
                PhoneMessage(seq: 2, role: .assistant, text: "Built and uploaded **2610270253**. The e2e run on tinker-desk passed 42/42.\n\nReady to submit build 2610270253 for review.", at: ago(4)),
            ],
            "a3": [
                PhoneMessage(seq: 120, role: .user, text: "Go back to two lines, one line is too cramped", at: ago(50)),
                PhoneMessage(seq: 121, role: .assistant, text: "Merged as `4700e57`. Each row has a project tile and the status on the right.", at: ago(25)),
            ],
            "a5": [
                PhoneMessage(seq: 1, role: .user, text: "Okay, let's go with it.", at: ago(8)),
            ],
        ]
        return (threads, messages)
    }
}
