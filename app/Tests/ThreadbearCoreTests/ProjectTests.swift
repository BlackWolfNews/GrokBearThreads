import XCTest
@testable import ThreadbearCore

final class ProjectTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testProjectDecodesFullAndToleratesUnknownFields() throws {
        let project = try decode(Project.self, """
        {"id":"p_3b1d9e20","title":"Threadbear","folders":["/Users/mike/dev/me/threadbear",5,"/Users/mike/dev/me/notes"],
         "goals":"Mike's own agent app.","state":"Projects next.","notes":"# Notes","createdBy":"librarian",
         "createdByThread":"th1","createdAt":"2026-10-20T10:00:00Z","updatedAt":"2026-10-27T10:00:00Z",
         "stateUpdatedAt":"2026-10-27T09:00:00Z","archived":false,"threadCount":"7","lastActivityAt":"2026-10-27T11:00:00Z",
         "colour":"teal"}
        """)
        XCTAssertEqual(project.title, "Threadbear")
        XCTAssertEqual(project.folders, ["/Users/mike/dev/me/threadbear", "/Users/mike/dev/me/notes"], "a folder that isn't a string is skipped")
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

    func testProjectLinks() throws {
        let project = try decode(Project.self, """
        {"id":"p_1","links":[{"title":"Live site","url":"https://cruise.example/"},{"url":"https://www.cruise.example/admin/"},
         {"title":"no url"},"https://loose.example"]}
        """)
        XCTAssertEqual(project.links, [
            ProjectLink(title: "Live site", url: "https://cruise.example/"),
            ProjectLink(title: "cruise.example/admin", url: "https://www.cruise.example/admin/"),
        ], "a link without a title is named by its address; a broken one is skipped")
        XCTAssertEqual(try decode(Project.self, #"{"id":"p_2"}"#).links, [], "none from a runner before links")
    }

    func testProjectLinkGroupsFollowTheThreadAndSkipEmptyOrArchived() throws {
        let thread = try decode(ThreadSummary.self, """
        {"id":"th1","projects":[{"id":"p_b","title":"B"},{"id":"p_a","title":"A"},{"id":"p_none","title":"N"},
         {"id":"p_old","title":"Old"},{"id":"p_gone","title":"Gone"}]}
        """)
        let link = [ProjectLink(title: "Site", url: "https://x.example")]
        let all = [
            Project(id: "p_a", title: "A", links: link),
            Project(id: "p_b", title: "B", links: link),
            Project(id: "p_none", title: "N"),
            Project(id: "p_old", title: "Old", links: link, archived: true),
        ]
        let groups = ProjectLinkGroups.build(thread: thread) { id in all.first { $0.id == id } }
        XCTAssertEqual(groups.map(\.id), ["p_b", "p_a"])
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
        XCTAssertEqual(built.sections[0].archived.map(\.id), ["t3"], "archived ones are kept apart, for the sidebar's fold")
        XCTAssertEqual(built.sections[1].archived, [], "hibernating isn't archived")
        XCTAssertEqual(built.unfiled.map(\.id), ["t4", "t5"], "a thread only in an archived project counts as in none")
        XCTAssertEqual(built.order, ["t2", "t1", "t4", "t5"])
        XCTAssertEqual(ProjectSections.threads(in: "b", from: threads).map(\.id), ["t3", "t2"], "the page lists put away ones too")
    }

    // MARK: The Projects page's cards

    func testCardsCountWhatEachProjectsThreadsAreDoing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let projects = [
            Project(id: "a", title: "A", updatedAt: now.addingTimeInterval(-86_400)),
            Project(id: "quiet", title: "Quiet", updatedAt: now.addingTimeInterval(-7 * 86_400)),
            Project(id: "gone", title: "Gone", archived: true),
        ]
        let at = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
        let inA = [ThreadProject(id: "a", title: "A")]
        let threads = [
            ThreadSummary(id: "run", title: "Running", status: .running, lastActivityAt: at(1), projects: inA),
            ThreadSummary(id: "bg", title: "", lastActivityAt: at(2),
                          background: [BackgroundTask(kind: .shell, description: "npm test")], projects: inA),
            ThreadSummary(id: "wait", title: "Waiting", status: .waiting, needsYou: true, lastActivityAt: at(3), projects: inA),
            ThreadSummary(id: "new", title: "Finished", needsYou: true, lastActivityAt: at(4), projects: inA),
            ThreadSummary(id: "bad", title: "Broke", status: .error, lastActivityAt: at(5), projects: inA),
            ThreadSummary(id: "old", title: "Old", lastActivityAt: at(6), projects: inA),
            ThreadSummary(id: "away", title: "Away", status: .waiting, lastActivityAt: at(7), archivedAt: now, projects: inA),
        ]
        let cards = ProjectCard.build(ProjectSections.build(projects: projects, threads: threads, now: now))
        XCTAssertEqual(cards.map(\.id), ["a", "quiet"], "archived projects get no card")
        XCTAssertEqual(cards[0].status, ProjectCardStatus(working: 2, needsYou: 1, failed: 1, unread: 1, open: 6),
                       "background work counts as working; archived threads aren't counted")
        XCTAssertEqual(cards[0].status.parts.map(\.text), ["1 needs you", "2 working", "1 failed", "1 new"])
        XCTAssertEqual(cards[0].recent, ["Running", "Untitled", "Waiting"])
        XCTAssertEqual(cards[0].lastActivityAt, at(1))
        XCTAssertTrue(cards[1].status.isQuiet)
        XCTAssertEqual(cards[1].status.parts, [])
        XCTAssertEqual(cards[1].recent, [])

        let both = [ThreadSummary(id: "x", title: "x", status: .running, projects: [ThreadProject(id: "a", title: "A"), ThreadProject(id: "quiet", title: "Quiet")])]
        let sections = ProjectSections.build(projects: projects, threads: both, now: now)
        XCTAssertEqual(ProjectCard.build(sections).map(\.status.working), [1, 1], "on both cards")
        XCTAssertEqual(ProjectCard.overall(sections).working, 1, "but one thread working")
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
        let project = Project(id: "p_b", title: "Poddle", folders: ["/p"])
        var one = ThreadSummary(id: "th1", title: "one")
        one.patches = [PatchInfo(id: "convex", source: "builtin", folder: "/p", projectId: "p_b"), PatchInfo(id: "tools")]
        var two = ThreadSummary(id: "th2", title: "two")
        two.patches = [PatchInfo(id: "convex", source: "builtin", folder: "/p", projectId: "p_b"),
                       PatchInfo(id: "poddle:tools", source: "project", folder: "/p", projectId: "p_b")]
        // In the project's folder: its patches are its own, untagged.
        var three = ThreadSummary(id: "th3", title: "three", cwd: "/p/app")
        three.patches = [PatchInfo(id: "xcode", source: "builtin"), PatchInfo(id: "mine", source: "home", file: "/p/x.ts")]
        let found = PatchGroups.patches(of: project, in: [one, two, three])
        XCTAssertEqual(found.map(\.patch.id), ["convex", "poddle:tools", "xcode"], "home patches aren't the project's")
        XCTAssertEqual(found.map(\.thread.id), ["th1", "th2", "th3"])
    }

    // MARK: A project's page in the pane

    func testProjectPaneBorrowsTheNewestOpenThreadsPanels() {
        let project = Project(id: "p_w", title: "Walkies", folders: ["/walkies"])
        let inW = [ThreadProject(id: "p_w", title: "Walkies")]
        let at = { (minutes: Double) in Date(timeIntervalSince1970: 1_000_000 - minutes * 60) }
        // Elsewhere, put in the project: the project's patches are tagged.
        var misc = ThreadSummary(id: "misc", title: "misc", cwd: "/misc", lastActivityAt: at(10), projects: inW)
        misc.patches = [PatchInfo(id: "checks", source: "project", file: "/misc/.threadbear/patches/checks.ts"),
                        PatchInfo(id: "walkies:convex", source: "builtin", folder: "/walkies", projectId: "p_w")]
        misc.panels = [Panel(id: "worktrees", title: "Worktrees", kind: .list, patch: "checks"),
                       Panel(id: "walkies:convex", title: "Convex", patch: "walkies:convex", projectId: "p_w")]
        // In a subfolder of the project's: the same, untagged.
        var inside = ThreadSummary(id: "inside", title: "inside", cwd: "/walkies-threads/x", lastActivityAt: at(1), projects: inW)
        inside.patches = [PatchInfo(id: "convex", source: "builtin")]
        inside.panels = [Panel(id: "convex", title: "Convex", patch: "convex")]
        let newer = ThreadSummary(id: "bare", title: "nothing", cwd: "/elsewhere", lastActivityAt: at(0), projects: inW)
        var away = ThreadSummary(id: "away", title: "away", cwd: "/walkies", lastActivityAt: at(0), archivedAt: at(0), projects: inW)
        away.patches = [PatchInfo(id: "xcode", source: "builtin")]
        away.panels = [Panel(id: "simulator", title: "Simulator", kind: .image, patch: "xcode")]
        let other = ThreadSummary(id: "other", title: "other", cwd: "/walkies", lastActivityAt: at(0))

        let pane = ProjectPane.standIn(for: project, threads: [misc, inside, newer, away, other])
        XCTAssertEqual(pane?.id, "misc", "a worktree outside the folder isn't inside it; nothing, archived or not in the project lose")
        XCTAssertEqual(pane?.patches.map(\.id), ["walkies:convex"], "only what came from the project")
        XCTAssertEqual(pane?.panels.map(\.id), ["walkies:convex"])

        var home = ThreadSummary(id: "home", title: "home", cwd: "/walkies/ios", lastActivityAt: at(5), projects: inW)
        home.patches = [PatchInfo(id: "convex", source: "builtin"), PatchInfo(id: "notes", source: "home", file: "/h/.threadbear/patches/notes.ts")]
        home.panels = [Panel(id: "convex", title: "Convex", patch: "convex"), Panel(id: "notes", title: "Notes", patch: "notes")]
        let mine = ProjectPane.standIn(for: project, threads: [misc, home])
        XCTAssertEqual(mine?.id, "home", "a thread in the folder has the project's patches as its own")
        XCTAssertEqual(mine?.panels.map(\.id), ["convex"], "not a home patch's panel")

        XCTAssertEqual(ProjectPane.standIn(for: project, threads: [newer, away])?.id, "away", "an archived thread when no open one has any")
        XCTAssertNil(ProjectPane.standIn(for: project, threads: [newer, other]))
        XCTAssertTrue(ProjectPane.isInside("/walkies", "/walkies/"))
        XCTAssertFalse(ProjectPane.isInside("/walkies2", "/walkies"))
    }

    func testPanelOriginForTheRailBadge() {
        var thread = ThreadSummary(id: "th1", title: "t", projects: [ThreadProject(id: "p_a", title: "Threadbear")])
        thread.patches = [
            PatchInfo(id: "convex", source: "builtin"),
            PatchInfo(id: "threadbear:convex", source: "builtin", folder: "/tb", projectId: "p_a"),
            PatchInfo(id: "tandem", source: "home", matched: ["/videos/James/edit.tandem"]),
            PatchInfo(id: "storybook", source: "home"),
            PatchInfo(id: "checks", source: "project"),
        ]
        let origin = { (patch: String, projectId: String?) in
            PanelOrigin.of(Panel(id: patch + ".p", title: "P", patch: patch, projectId: projectId), in: thread)
        }
        XCTAssertEqual(origin("convex", nil), .builtin)
        XCTAssertEqual(origin("threadbear:convex", nil), .project(id: "p_a"), "the patch's project")
        XCTAssertEqual(origin("convex", "p_a"), .project(id: "p_a"), "the panel's own project wins")
        XCTAssertEqual(origin("tandem", nil), .tool(matched: ["/videos/James/edit.tandem"]))
        XCTAssertEqual(origin("storybook", nil), .home)
        XCTAssertEqual(origin("checks", nil), .folder)
        XCTAssertEqual(origin("gone", nil), .folder, "a summary a moment behind")
        XCTAssertNil(PanelOrigin.project(id: "p_a").symbol, "drawn with the project's icon")
        XCTAssertEqual(PanelOrigin.project(id: "p_a").tip("Convex", projectTitle: "Threadbear"), "Convex, from the Threadbear project")
        XCTAssertEqual(PanelOrigin.project(id: "p_a").tip("Convex", projectTitle: nil), "Convex, from a project")
        XCTAssertEqual(origin("tandem", nil).tip("Timeline", projectTitle: nil), "Timeline, for edit.tandem")
    }

    // MARK: Words

    func testLibrarianWords() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .working, current: LibrarianJob(threadId: "t", threadTitle: "Rename the tabs"))),
                       "Looking at \u{201C}Rename the tabs\u{201D}")
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .off)), "Off")
        XCTAssertEqual(LibrarianText.state(LibrarianStatus(state: .idle, paused: true)), "Paused")
        XCTAssertEqual(LibrarianText.today(LibrarianStatus(looksToday: 1)), "1 look today")
        XCTAssertEqual(LibrarianText.today(LibrarianStatus(looksToday: 208, skippedToday: 40, tokensToday: 768_951, notionalTodayUsd: 0.153)),
                       "208 looks today · 40 skipped · 769k tokens", "no money: looks run on a Claude login")
        XCTAssertEqual(LibrarianText.tokens(820), "820")
        XCTAssertEqual(LibrarianText.tokens(1_234_567), "1.2M")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(240), now: now), "in 4m")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(LibrarianText.due(now.addingTimeInterval(-600), now: now), "waiting")
        XCTAssertEqual(LibrarianText.why(LibrarianJob(threadId: "t", reason: .moved)), "Moved to another folder")
        XCTAssertEqual(LibrarianText.why(LibrarianJob(threadId: "t", reason: .moved, why: "Moved to ~/dev/poddle")), "Moved to ~/dev/poddle")
    }
}
