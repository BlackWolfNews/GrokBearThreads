import Foundation
import Testing
@testable import ThreadbearKit

@Suite struct DecodingTests {
    @Test func identityCarriesTheBackendVersionAndOldBackendsAreSaidToBeOld() throws {
        let current = try JSONDecoder().decode(PhoneIdentity.self, from: Data(#"{"name":"iphone","expiresAt":"2027-01-26T00:00:00.000Z","apiVersion":1}"#.utf8))
        #expect(current.apiVersion == 1)
        #expect(BackendCompatibility.problem(current) == nil)
        // A backend deployed before convex/version.ts has no apiVersion at all.
        let old = try JSONDecoder().decode(PhoneIdentity.self, from: Data(#"{"name":"iphone","expiresAt":"2027-01-26T00:00:00.000Z"}"#.utf8))
        #expect(old.apiVersion == nil)
        #expect(BackendCompatibility.problem(old) != nil)
    }

    @Test func messagePageDecodesToolLinesAndGroupsThem() throws {
        let json = #"""
        {"hasMore":true,"messages":[
          {"seq":10.0,"role":"user","text":"Ship it","at":"2026-10-28T00:00:00.000Z"},
          {"seq":11.0,"role":"tool","text":"Run the unit tests","toolKind":"command","at":"2026-10-28T00:00:01.000Z"},
          {"seq":12.0,"role":"tool","text":"Edited ~/dev/x.ts","toolKind":"edit","at":"2026-10-28T00:00:02.000Z"},
          {"seq":13.0,"role":"assistant","text":"Done.","at":"2026-10-28T00:00:03.000Z"},
          {"seq":14.0,"role":"tool","text":"Read README.md","toolKind":"read","at":"2026-10-28T00:00:04.000Z"}
        ]}
        """#
        let page = try JSONDecoder().decode(MessagePage.self, from: Data(json.utf8))
        #expect(page.hasMore)
        #expect(page.messages[1].role == .tool && page.messages[1].toolKind == "command")
        let items = ThreadItem.group(page.messages)
        #expect(items.count == 4)
        guard case let .tools(run) = items[1] else { Issue.record("expected a tool run"); return }
        #expect(run.map(\.seq) == [11, 12])
        guard case .tools = items[3] else { Issue.record("expected a trailing run"); return }
        #expect(items.map(\.id) == [10, 11, 13, 14])
    }

    /// Sealed in Node the way convex/push.ts seal() does, with a key of 32
    /// sevens: the phone must open what the backend seals.
    @Test func pushSealOpensWhatTheBackendSealed() {
        let key = Data(repeating: 7, count: 32)
        let opened = PushSeal.open("AiSVcm4cKdtZwL3c/Uwy7/xLI/glgedZynZE0KGAPg1kAmJEyB2VjF4/jTFQARFe9Fvu853UYEiuEU6uMrlKm9HezW8YilUyjUeS13rAMw==", key: key)
        #expect(opened?.title == "Fix the dock")
        #expect(opened?.body == "Should I push it?")
        #expect(PushSeal.open("AiSVcm4cKdtZwL3c/Uwy7/xLI/glgedZynZE0KGAPg1kAmJEyB2VjF4/jTFQARFe9Fvu853UYEiuEU6uMrlKm9HezW8YilUyjUeS13rAMw==", key: Data(repeating: 8, count: 32)) == nil, "the wrong key opens nothing")
    }

    @Test func wokenThreadSaysSoUntilOpened() throws {
        let json = """
        {"threadId":"t1","runnerId":"m5","title":"A","cwd":"/x","accountId":"claude-3","provider":"claude",
         "status":"idle","needsYou":true,"unread":true,"preview":"","lastActivityAt":"2026-10-27T08:23:19.962Z",
         "woke":{"at":"2026-10-30T02:24:21.575Z","since":"2026-10-30T02:23:21.575Z"}}
        """
        var row = try JSONDecoder().decode(PhoneThread.self, from: Data(json.utf8))
        #expect(row.woke?.since != nil)
        #expect(RowStatus.text(row, now: Date()) == "Woke up")
        row.woke = nil
        #expect(RowStatus.text(row, now: row.lastActivityAt) == "now")
        // A turn running on it says so instead.
        row.woke = Woke(at: Date())
        row.status = .running
        #expect(RowStatus.text(row, now: Date()) == "Working")
    }

    @Test func threadRowDecodesWithISOAndMillisecondDates() throws {
        let json = """
        [{"threadId":"t1","runnerId":"m5","title":"A","cwd":"/Users/m/dev/me/misc","accountId":"claude-3",
          "provider":"claude","status":"running","needsYou":false,"unread":true,"preview":"hi",
          "lastActivityAt":"2026-10-27T08:23:19.962Z","snoozedUntil":1761553399962,"working":"Running npm test",
          "projects":[{"id":"p1","title":"Threadbear"}]},
         {"threadId":"t2","runnerId":"m5","title":"B","cwd":"/x","accountId":"a","provider":"codex",
          "status":"somethingNew","needsYou":true,"unread":false,"preview":"","lastActivityAt":1761553399962,
          "pendingApproval":{"approvalId":"ap","kind":"approval","name":"Bash","title":"Run","options":["allow","deny","later"],"inputSummary":"ls"}}]
        """
        let rows = try JSONDecoder().decode([PhoneThread].self, from: Data(json.utf8))
        #expect(rows.count == 2)
        #expect(rows[0].status == .running)
        #expect(rows[0].snoozedUntil != nil)
        #expect(rows[0].archivedAt == nil)
        #expect(rows[0].woke == nil)
        #expect(rows[0].placeText == "Threadbear")
        #expect(rows[1].status == .unknown)
        #expect(rows[1].folderName == "x")
        guard case let .approval(_, _, _, options, summary) = rows[1].pendingApproval else {
            Issue.record("expected an approval")
            return
        }
        #expect(options == [.allow, .deny])
        #expect(summary == "ls")
    }

    @Test func questionAndMessagesDecode() throws {
        let json = """
        {"thread":{"threadId":"t","runnerId":"m5","title":"Q","cwd":"/","accountId":"a","provider":"claude",
          "status":"waiting","needsYou":true,"unread":false,"preview":"","lastActivityAt":0,
          "pendingApproval":{"approvalId":"q","kind":"question","questions":[{"question":"Which?","multiSelect":false,"options":[{"label":"A"}]}]}},
         "messages":[{"seq":3.0,"role":"user","text":"go","origin":"phone","at":1000}]}
        """
        let detail = try JSONDecoder().decode(ThreadDetail.self, from: Data(json.utf8))
        #expect(detail.messages.first?.seq == 3)
        #expect(detail.messages.first?.origin == "phone")
        guard case let .question(id, questions) = detail.thread.pendingApproval else {
            Issue.record("expected a question")
            return
        }
        #expect(id == "q")
        #expect(questions.first?.options.first?.label == "A")
    }

    @Test func nullDetailDecodes() throws {
        let detail = try JSONDecoder().decode(ThreadDetail?.self, from: Data("null".utf8))
        #expect(detail == nil)
    }
}

@Suite struct InboxTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func thread(_ id: String, _ minutesAgo: Double, status: ThreadStatus = .idle, needsYou: Bool = false,
                approval: Bool = false, working: String? = nil, snoozed: Bool = false) -> PhoneThread {
        PhoneThread(threadId: id, title: id, status: status, needsYou: needsYou,
                    lastActivityAt: now.addingTimeInterval(-minutesAgo * 60),
                    snoozedUntil: snoozed ? now.addingTimeInterval(600) : nil, working: working,
                    pendingApproval: approval ? .approval(id: "x", name: "", title: "", options: [.allow], inputSummary: nil) : nil)
    }

    @Test func ordersByUrgencyThenNewest() {
        let sections = InboxSections.build([
            thread("done", 1),
            thread("unread", 5, needsYou: true),
            thread("asking", 30, status: .waiting, approval: true),
            thread("failed", 2, status: .error, needsYou: true),
            thread("busy", 0, status: .running, working: "Bear with me"),
            thread("background", 3, working: "1 sub-agent"),
            thread("snoozed", 0, snoozed: true),
        ], now: now)
        #expect(sections.inbox.map(\.threadId) == ["asking", "failed", "unread", "done"])
        #expect(sections.running.map(\.threadId) == ["busy", "background"])
        #expect(sections.needsYouCount == 3)
    }

    @Test func aQuestionStaysInTheInboxWhileBackgroundWorkRuns() {
        let sections = InboxSections.build([thread("q", 1, status: .waiting, approval: true, working: "1 sub-agent")], now: now)
        #expect(sections.inbox.map(\.threadId) == ["q"])
    }

    @Test func rowStatusText() {
        #expect(RowStatus.text(thread("a", 1, status: .waiting, approval: true), now: now) == "Needs you")
        #expect(RowStatus.kind(thread("a", 1, status: .waiting, approval: true)) == .needsYou)
        #expect(RowStatus.text(thread("b", 1, status: .running), now: now) == "Working")
        #expect(RowStatus.text(thread("c", 5), now: now) == "5m")
        #expect(RowStatus.kind(thread("c", 5)) == .time)
        #expect(RowStatus.workingLabel(since: now.addingTimeInterval(-53), now: now) == "53s")
        #expect(RowStatus.workingLabel(since: now.addingTimeInterval(-62 * 60), now: now) == "1h 2m")
    }

    @Test func projectRowsDecodeWithAndWithoutIcons() throws {
        let json = #"""
        [{"id":"p1","runnerId":"r1","title":"Garden","archived":false,"icon":{"symbol":"leaf","url":"https://x.convex.cloud/api/storage/abc","by":"librarian"}},
         {"id":"p2","runnerId":"r1","title":"Site","archived":false,"icon":{"url":"not a url","by":"mike"}},
         {"id":"p3","runnerId":"r1","title":"Old","archived":false}]
        """#
        let rows = try JSONDecoder().decode([PhoneProject].self, from: Data(json.utf8))
        #expect(rows[0].icon?.symbol == "leaf")
        #expect(rows[0].icon?.url?.host() == "x.convex.cloud")
        #expect(rows[1].icon?.url == nil)
        #expect(rows[2].icon == nil)
        #expect(ProjectMark.letter("7 day plan") == "7")
        #expect(ProjectMark.letter("🐻") == "?")
    }

    /// Every project a sample thread is in has a sample project, so the
    /// demo's rows show icons.
    @Test func sampleProjectsCoverTheSampleThreads() {
        let sample = FakeBackend.sample(now: .now)
        let ids = Set(FakeBackend.sampleProjects.map(\.id))
        for thread in sample.threads {
            for ref in thread.projects ?? [] { #expect(ids.contains(ref.id), "no sample project \(ref.id)") }
        }
    }

    @Test func previewIsPlain() {
        #expect(PreviewText.plain("**Merged** as `4700e57`, see [the PR](https://x)") == "Merged as 4700e57, see the PR")
    }
}

@Suite struct AnswersTests {
    let questions = [
        Question(question: "Which?", header: "Pick", options: [.init(label: "A"), .init(label: "B")]),
        Question(question: "Extras?", header: "Extras", multiSelect: true, options: [.init(label: "X"), .init(label: "Y")]),
    ]

    @Test func buildsAnswersLikeTheMac() {
        let answers = Answers.build(questions, chosen: [0: ["B"], 1: ["X", "Y"]], typed: "Z")
        #expect(answers == ["Which?": "B", "Extras?": "X, Y, Z"])
        #expect(Answers.summary(questions, answers: answers) == "Pick B · Extras X, Y, Z")
    }

    @Test func typedReplacesASingleChoiceOnTheLastQuestion() {
        let one = [Question(question: "Which?", options: [.init(label: "A")])]
        #expect(Answers.build(one, chosen: [0: ["A"]], typed: "something else") == ["Which?": "something else"])
    }
}

@Suite struct PairingTests {
    @Test func parsesAPairLink() throws {
        let url = URL(string: "threadbear://pair?url=https://happy-bear-123.convex.cloud&token=tb_abc")!
        let pairing = try #require(Pairing.parse(url))
        #expect(pairing.deploymentURL.absoluteString == "https://happy-bear-123.convex.cloud")
        #expect(pairing.token == "tb_abc")
        #expect(Pairing.parse(pairing.link) == pairing)
    }

    @Test func siteURLBecomesCloud() throws {
        let url = URL(string: "threadbear://pair?url=https://happy-bear-123.convex.site&token=t")!
        #expect(try #require(Pairing.parse(url)).deploymentURL.host() == "happy-bear-123.convex.cloud")
    }

    @Test func refusesOtherHosts() {
        #expect(Pairing.parse(URL(string: "threadbear://pair?url=https://evil.example.com&token=t")!) == nil)
        #expect(Pairing.parse(URL(string: "threadbear://pair?url=http://a.convex.cloud&token=t")!) == nil)
    }
}

@Suite struct FakeBackendTests {
    @Test func sendRunsATurnAndReplies() async throws {
        let backend = FakeBackend(turnDelay: .milliseconds(10))
        _ = try await backend.send(threadId: "a3", text: "thanks")
        try await Task.sleep(for: .milliseconds(100))
        var iterator = backend.thread("a3").makeAsyncIterator()
        let detail = try #require(try await iterator.next() ?? nil)
        #expect(detail.messages.suffix(2).map(\.role) == [.user, .assistant])
        #expect(detail.thread.status == .idle)
        #expect(detail.thread.unread)
    }

    /// The sample threads are what App Review and the App Store screenshots
    /// see (the pair screen's "Look around with sample threads"), so none of
    /// Mike's own projects, machines or folders can be in them.
    @Test func sampleDataHasNothingPersonal() throws {
        let sample = FakeBackend.sample(now: .now)
        let encoder = JSONEncoder()
        let text = (String(decoding: try encoder.encode(sample.threads), as: UTF8.self)
            + String(decoding: try encoder.encode(sample.messages), as: UTF8.self)
            + String(decoding: try encoder.encode(FakeBackend.sampleProjects), as: UTF8.self)).lowercased()
        for word in ["poddle", "walkies", "quick ask", "stash it", "cannvas", "bruce", "tinker", "backblaze",
                     "shed", "juice", "mike", "dev/me", "/users/", "convex.cloud"] {
            #expect(!text.contains(word), "the sample data mentions \(word)")
        }
    }

    /// The demo (and App Review) shouldn't be told to update a Mac it doesn't have.
    @Test func fakeBackendIsNeverTooOld() async throws {
        #expect(BackendCompatibility.problem(try await FakeBackend().me()) == nil)
    }

    @Test func archiveMovesToTheDen() async throws {
        let backend = FakeBackend()
        _ = try await backend.update(threadId: "a4", change: .archive)
        var den = backend.threads(.den).makeAsyncIterator()
        #expect(try await den.next()?.contains { $0.threadId == "a4" } == true)
    }
}

@Suite struct LocalAndErrorTests {
    @Test func localBackendOnlyWhenAllowed() {
        let url = URL(string: "threadbear://pair?url=http://127.0.0.1:3210&token=t")!
        #expect(Pairing.parse(url) == nil)
        #expect(Pairing.parse(url, allowLocal: true)?.deploymentURL.absoluteString == "http://127.0.0.1:3210")
    }

    @Test func anUnreadableOptionalDateIsAbsent() throws {
        let json = """
        {"threadId":"t","runnerId":"m5","title":"A","cwd":"/","accountId":"a","provider":"claude","status":"idle",
         "needsYou":false,"unread":false,"preview":"","lastActivityAt":"2026-10-27T08:23:19.962Z","lastActivityMs":1,
         "view":"inbox","createdAt":"2026-10-27T08:00:00Z","snoozedUntil":"restart"}
        """
        let row = try JSONDecoder().decode(PhoneThread.self, from: Data(json.utf8))
        #expect(row.snoozedUntil == nil)
    }

    @Test func notFoundBecomesNilForAThread() async throws {
        let backend = ConvexBackend(transport: FailingTransport(error: .notFound("no such thread")), token: "t")
        var iterator = backend.thread("x").makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == .some(nil))
    }
}

struct FailingTransport: ConvexTransport {
    var error: TransportError
    func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data { throw error }
    func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data { throw error }
    func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func connectionStates() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}

@Suite struct EarlierMessagesTests {
    @Test func hasEarlierFollowsEarliestSeq() {
        var thread = PhoneThread(threadId: "t", title: "t", lastActivityAt: .now)
        #expect(!thread.hasEarlier(than: 50))
        thread.earliestSeq = 3
        #expect(thread.hasEarlier(than: 50))
        #expect(!thread.hasEarlier(than: 3))
        #expect(!thread.hasEarlier(than: nil))
    }

    @Test func fakeLoadEarlierPrependsOlderMessages() async throws {
        let backend = FakeBackend(turnDelay: .milliseconds(20))
        _ = try await backend.loadEarlier(threadId: "a3", beforeSeq: 120)
        try await Task.sleep(for: .milliseconds(100))
        var iterator = backend.thread("a3").makeAsyncIterator()
        let detail = try #require(try await iterator.next() ?? nil)
        #expect(detail.messages.first?.seq == 70)
        #expect(detail.messages.map(\.seq) == detail.messages.map(\.seq).sorted())
        #expect(detail.thread.hasEarlier(than: detail.messages.first?.seq))
    }
}
