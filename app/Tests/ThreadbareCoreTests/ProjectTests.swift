import XCTest
@testable import ThreadbareCore

final class ProjectTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testProjectDecodesFullAndToleratesUnknownFields() throws {
        let project = try decode(Project.self, """
        {"id":"p_3b1d9e20","title":"Threadbear","folders":["/Users/mike/dev/me/threadbare",5,"/Users/mike/dev/me/notes"],
         "goals":"Mike's own agent app.","state":"Projects next.","notes":"# Notes","createdBy":"librarian",
         "createdByThread":"th1","createdAt":"2026-10-20T10:00:00Z","updatedAt":"2026-10-27T10:00:00Z",
         "stateUpdatedAt":"2026-10-27T09:00:00Z","archived":false,"threadCount":"7","lastActivityAt":"2026-10-27T11:00:00Z",
         "colour":"teal"}
        """)
        XCTAssertEqual(project.title, "Threadbear")
        XCTAssertEqual(project.folders, ["/Users/mike/dev/me/threadbare", "/Users/mike/dev/me/notes"], "a folder that isn't a string is skipped")
        XCTAssertEqual(project.createdBy, .librarian)
        XCTAssertEqual(project.createdByThread, "th1")
        XCTAssertEqual(project.threadCount, 7)
        XCTAssertEqual(project.lastActivityAt, ISO8601.parse("2026-10-27T11:00:00Z"))
        XCTAssertFalse(project.archived)
    }

    func testProjectIcons() throws {
        let picture = try decode(Project.self, """
        {"id":"p_1","icon":{"image":{"path":"/d/project-icons/p_1-ab.png","mediaType":"image/png","width":256,"height":256},
         "from":"/r/App/AppIcon.png","by":"librarian","updatedAt":"2026-10-27T10:00:00Z","shade":"new"}}
        """)
        XCTAssertEqual(picture.icon?.image?.path, "/d/project-icons/p_1-ab.png")
        XCTAssertEqual(picture.icon?.from, "/r/App/AppIcon.png")
        XCTAssertEqual(picture.icon?.isChosen, false)
        let symbol = try decode(Project.self, #"{"id":"p_2","icon":{"symbol":"film","by":"mike"}}"#)
        XCTAssertEqual(symbol.icon?.symbol, "film")
        XCTAssertEqual(symbol.icon?.isChosen, true)
        let broken = try decode(Project.self, #"{"id":"p_3","icon":"film"}"#)
        XCTAssertNil(broken.icon, "an icon that isn't an object is dropped, not the project")
        XCTAssertNil(try decode(Project.self, #"{"id":"p_4"}"#).icon)
    }

    func testProjectWithOnlyAnId() throws {
        let project = try decode(Project.self, #"{"id":"p_1","createdBy":"someone-new"}"#)
        XCTAssertEqual(project.title, "Untitled project")
        XCTAssertEqual(project.folders, [])
        XCTAssertEqual(project.goals, "")
        XCTAssertEqual(project.createdBy, .agent, "an author from a newer runner reads as an agent")
        XCTAssertEqual(project.threadCount, 0)
        XCTAssertNil(project.lastActivityAt)
    }

    func testThreadSummaryProjects() throws {
        let thread = try decode(ThreadSummary.self, """
        {"id":"th1","projects":[{"id":"p_a","title":"Threadbear","by":"mike","pinned":true,"at":"2026-10-27T10:00:00Z"},
         {"title":"no id"},{"id":"p_b","title":"Poddle","by":"librarian"}]}
        """)
        XCTAssertEqual(thread.projects.map(\.id), ["p_a", "p_b"])
        XCTAssertTrue(thread.projects[0].pinned)
        XCTAssertEqual(thread.projects[0].by, .mike)
        XCTAssertFalse(thread.projects[1].pinned)
        XCTAssertEqual(try decode(ThreadSummary.self, #"{"id":"old"}"#).projects, [], "a runner from before projects sends none")
        // Exports round-trip (`tb export`, the fixtures).
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.projects, thread.projects)
    }

    func testPatchItemsCarryFolderAndProject() throws {
        let thread = try decode(ThreadSummary.self, """
        {"id":"th1",
         "actions":[{"id":"poddle:tools.check","title":"Check","kind":"command","command":"npm test","patch":"poddle:tools","folder":"/p","projectId":"p_b"}],
         "hooks":[{"id":"tools.tsc","title":"Typecheck","command":"tsc","patch":"tools","folder":"/p","projectId":"p_b"}],
         "panels":[{"id":"convex.dashboard","title":"Convex","url":"https://x","patch":"convex","projectId":"p_b"}],
         "patches":[{"id":"convex","source":"builtin","folder":"/p","projectId":"p_b"},{"id":"tools","source":"project"}]}
        """)
        XCTAssertEqual(thread.actions.first?.folder, "/p")
        XCTAssertEqual(thread.actions.first?.projectId, "p_b")
        XCTAssertEqual(thread.hooks.first?.projectId, "p_b")
        XCTAssertEqual(thread.panels.first?.projectId, "p_b")
        XCTAssertEqual(thread.patches.map(\.projectId), ["p_b", nil])
        XCTAssertEqual(thread.patches.first?.folder, "/p")
    }

    func testLibrarianStatusDecodes() throws {
        let status = try decode(LibrarianStatus.self, """
        {"state":"working","paused":false,
         "current":{"threadId":"th1","threadTitle":"Rename the tabs","reason":"first-turn","why":"Its first turn ended","dueAt":"2026-10-27T10:00:00Z","startedAt":"2026-10-27T10:00:05Z"},
         "queue":[{"threadId":"th2","threadTitle":"Poster","reason":"new-folder","why":"Edited files in ~/dev/poddle","dueAt":"2026-10-27T10:01:00Z"},
                  {"threadId":"th3","reason":"teleported"},{"reason":"moved"}],
         "recent":[{"id":"e1","at":"2026-10-27T09:00:00Z","threadId":"th4","threadTitle":"CI","reason":"catch-up","outcome":"updated","text":"Photo sync's state","projectIds":["p_a"],"costUsd":0.0004},
                   {"id":"e2","threadId":"th5","outcome":"exploded","text":"?"}],
         "looksToday":14,"spentTodayUsd":0.031}
        """)
        XCTAssertEqual(status.state, .working)
        XCTAssertEqual(status.current?.threadTitle, "Rename the tabs")
        XCTAssertEqual(status.current?.startedAt, ISO8601.parse("2026-10-27T10:00:05Z"))
        XCTAssertEqual(status.queue.map(\.threadId), ["th2", "th3"], "a job with no thread is skipped")
        XCTAssertEqual(status.queue[1].reason, .asked, "an unknown reason reads as asked")
        XCTAssertEqual(status.recent.map(\.outcome), [.updated, .other])
        XCTAssertEqual(status.recent.first?.projectIds, ["p_a"])
        XCTAssertEqual(status.pendingCount, 3)
        XCTAssertEqual(status.looksToday, 14)
        XCTAssertEqual(status.spentTodayUsd, 0.031, accuracy: 0.0001)
    }

    func testLibrarianStatusWithAlmostNothing() throws {
        let paused = try decode(LibrarianStatus.self, #"{"paused":true}"#)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.queue, [])
        XCTAssertEqual(try decode(LibrarianStatus.self, #"{"state":"dreaming"}"#).state, .idle)
    }

    func testNotifications() async throws {
        let transport = FakeTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        transport.push(E.json(["jsonrpc": "2.0", "method": "projects.updated",
                               "params": ["projects": [["id": "p_a", "title": "Threadbear"], ["title": "no id"]]]]))
        transport.push(E.json(["jsonrpc": "2.0", "method": "librarian.updated",
                               "params": ["librarian": ["state": "off", "reason": "No OpenRouter key", "paused": false, "queue": [], "recent": []]]]))
        var iterator = client.notifications.makeAsyncIterator()
        guard case .projectsUpdated(let projects)? = await iterator.next() else { return XCTFail("no projects.updated") }
        XCTAssertEqual(projects.map(\.id), ["p_a"])
        guard case .librarianUpdated(let librarian)? = await iterator.next() else { return XCTFail("no librarian.updated") }
        XCTAssertEqual(librarian.state, .off)
        XCTAssertEqual(LibrarianText.state(librarian), "Off: No OpenRouter key")
    }

    // MARK: Requests

    func testUpdateParamsOnlyWhatChanged() {
        XCTAssertEqual(ProjectUpdate(archived: true).params, ["archived": .bool(true)])
        let params = ProjectUpdate(folders: ["/a", "/b"], notes: "").params
        XCTAssertEqual(params["folders"], .array([.string("/a"), .string("/b")]))
        XCTAssertEqual(params["notes"], .string(""), "an emptied field is sent, so it's cleared")
        XCTAssertNil(params["title"])
    }

    func testSetProjectsAndCreateParams() {
        XCTAssertEqual(SetProjectsRequest(threadId: "th1", remove: ["p_a"]).params,
                       ["threadId": .string("th1"), "remove": .array([.string("p_a")])])
        let create = NewProjectRequest(title: "Poddle", threadIds: ["th1"]).params
        XCTAssertEqual(create["title"], .string("Poddle"))
        XCTAssertEqual(create["threadIds"], .array([.string("th1")]))
        XCTAssertNil(create["folders"])
    }

    // MARK: The Projects view

    private func thread(_ id: String, minutesAgo: Double, projects: [String] = [], archived: Bool = false, snoozed: Bool = false) -> ThreadSummary {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return ThreadSummary(
            id: id, title: id, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60),
            snoozedUntil: snoozed ? now.addingTimeInterval(3600) : nil, archivedAt: archived ? now : nil,
            projects: projects.map { ThreadProject(id: $0, title: $0.uppercased()) }
        )
    }

    func testSectionsNewestFirstWithAThreadInTwoAndUnfiledLast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let projects = [
            Project(id: "a", title: "A", updatedAt: now.addingTimeInterval(-86_400)),
            Project(id: "b", title: "B", updatedAt: now.addingTimeInterval(-86_400)),
            Project(id: "gone", title: "Gone", archived: true),
            Project(id: "quiet", title: "Quiet", updatedAt: now.addingTimeInterval(-7 * 86_400)),
        ]
        let threads = [
            thread("t1", minutesAgo: 30, projects: ["a"]),
            thread("t2", minutesAgo: 5, projects: ["b", "a"]),
            thread("t3", minutesAgo: 1, projects: ["b"], archived: true),
            thread("t4", minutesAgo: 2),
            thread("t5", minutesAgo: 3, projects: ["gone"]),
            thread("t6", minutesAgo: 4, projects: ["a"], snoozed: true),
        ]
        let built = ProjectSections.build(projects: projects, threads: threads, now: now)
        XCTAssertEqual(built.sections.map(\.project.id), ["b", "a", "quiet"], "b's archived thread is its newest activity; archived projects are left out")
        XCTAssertEqual(built.sections[0].threads.map(\.id), ["t2"], "archived threads aren't listed")
        XCTAssertEqual(built.sections[1].threads.map(\.id), ["t2", "t1"], "a thread in two projects is under both; hibernating ones aren't")
        XCTAssertEqual(built.sections[2].threads, [])
        XCTAssertEqual(built.unfiled.map(\.id), ["t4", "t5"], "a thread only in an archived project counts as in none")
        XCTAssertEqual(built.order, ["t2", "t1", "t4", "t5"])
        XCTAssertEqual(ProjectSections.threads(in: "b", from: threads).map(\.id), ["t3", "t2"], "the page lists put away ones too")
    }

    // MARK: The Patches tab

    func testPatchGroupsOwnFolderFirstThenEachProject() {
        var thread = ThreadSummary(id: "th1", title: "t", projects: [ThreadProject(id: "p_a", title: "Threadbear"), ThreadProject(id: "p_b", title: "Poddle")])
        thread.patches = [
            PatchInfo(id: "convex", source: "builtin", folder: "/poddle", projectId: "p_b"),
            PatchInfo(id: "tools", source: "project"),
            PatchInfo(id: "checks", source: "project", folder: "/tb", projectId: "p_a"),
            PatchInfo(id: "old", source: "project", folder: "/x", projectId: "p_gone"),
        ]
        let groups = PatchGroups.group(thread) { $0 == "p_gone" ? "Gone" : nil }
        XCTAssertEqual(groups.map(\.title), [nil, "Threadbear", "Poddle", "Gone"])
        XCTAssertEqual(groups.map { $0.patches.map(\.id) }, [["tools"], ["checks"], ["convex"], ["old"]])
        thread.patches = [PatchInfo(id: "tools")]
        XCTAssertEqual(PatchGroups.group(thread).count, 1)
        XCTAssertNil(PatchGroups.group(thread).first?.title, "no headings when nothing came from a project")
        thread.patches = []
        XCTAssertEqual(PatchGroups.group(thread), [])
    }

    func testProjectPatchesAcrossThreadsEachOnce() {
        var one = ThreadSummary(id: "th1", title: "one")
        one.patches = [PatchInfo(id: "convex", source: "builtin", folder: "/p", projectId: "p_b"), PatchInfo(id: "tools")]
        var two = ThreadSummary(id: "th2", title: "two")
        two.patches = [PatchInfo(id: "convex", source: "builtin", folder: "/p", projectId: "p_b"),
                       PatchInfo(id: "poddle:tools", source: "project", folder: "/p", projectId: "p_b")]
        let found = PatchGroups.patches(of: "p_b", in: [one, two])
        XCTAssertEqual(found.map(\.patch.id), ["convex", "poddle:tools"])
        XCTAssertEqual(found.map(\.thread.id), ["th1", "th2"])
    }

    // MARK: Words

    func testLibrarianWords() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .working, current: LibrarianJob(threadId: "t", threadTitle: "Rename the tabs"))),
                       "Looking at \u{201C}Rename the tabs\u{201D}")
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .off)), "Off")
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .idle, paused: true)), "Paused")
        XCTAssertEqual(LibrarianText.today(LibrarianStatus(looksToday: 1, spentTodayUsd: 0)), "1 look today · $0")
        XCTAssertEqual(LibrarianText.today(LibrarianStatus(looksToday: 14, spentTodayUsd: 0.031)), "14 looks today · $0.03")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(240), now: now), "in 4m")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(-600), now: now), "waiting")
        XCTAssertEqual(LibrarianText.why(LibrarianJob(threadId: "t", reason: .moved)), "Moved to another folder")
        XCTAssertEqual(LibrarianText.why(LibrarianJob(threadId: "t", reason: .moved, why: "Moved to ~/dev/poddle")), "Moved to ~/dev/poddle")
    }
}
