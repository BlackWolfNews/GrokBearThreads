import XCTest
@testable import ThreadbearCore

final class ScheduleTests: XCTestCase {
    // MARK: Decoding

    func testScheduleDecodesFullAndToleratesUnknownFields() throws {
        let json = """
        {"id":"sc1","title":"Morning check","text":"Check the deploy.","cron":"0 9 * * 1-5","timezone":"Australia/Perth",
         "whenText":"Weekdays at 9:00","threadId":"th1","paused":false,"createdAt":"2026-10-26T10:00:00Z",
         "updatedAt":"2026-10-26T11:00:00Z","createdBy":"th1","nextRunAt":"2026-10-28T01:00:00Z","runs":3,
         "lastRun":{"at":"2026-10-27T01:00:00Z","outcome":"skipped","threadId":"th1","note":"busy","extra":1},
         "somethingNew":{"a":[1,2]}}
        """
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        XCTAssertEqual(schedule.title, "Morning check")
        XCTAssertEqual(schedule.cron, "0 9 * * 1-5")
        XCTAssertEqual(schedule.timezone, "Australia/Perth")
        XCTAssertEqual(schedule.whenText, "Weekdays at 9:00")
        XCTAssertEqual(schedule.threadId, "th1")
        XCTAssertEqual(schedule.createdBy, "th1")
        XCTAssertEqual(schedule.runs, 3)
        XCTAssertEqual(schedule.nextRunAt, ISO8601.parse("2026-10-28T01:00:00Z"))
        XCTAssertEqual(schedule.lastRun?.outcome, .skipped)
        XCTAssertEqual(schedule.lastRun?.note, "busy")
        XCTAssertFalse(schedule.isOneOff)
        XCTAssertTrue(schedule.isActive)
        XCTAssertTrue(schedule.belongs(to: "th1"))
        XCTAssertFalse(schedule.belongs(to: "th2"))
    }

    func testScheduleWithOnlyAnIdAndText() throws {
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(#"{"id":"x","text":"First line\nSecond","runs":"2"}"#.utf8))
        XCTAssertEqual(schedule.title, "First line", "the title defaults to the first line of the text")
        XCTAssertFalse(schedule.paused)
        XCTAssertNil(schedule.threadId)
        XCTAssertEqual(schedule.runs, 2)
        XCTAssertTrue(schedule.isOneOff)
    }

    func testFinishedOneOffAndUnknownOutcome() throws {
        let json = #"{"id":"x","title":"t","text":"t","at":"2026-10-27T05:30:00Z","whenText":"Once","paused":false,"finishedAt":"2026-10-27T05:30:02Z","lastRun":{"outcome":"teleported"}}"#
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        XCTAssertEqual(schedule.at, ISO8601.parse("2026-10-27T05:30:00Z"))
        XCTAssertTrue(schedule.isFinished)
        XCTAssertFalse(schedule.isActive)
        XCTAssertEqual(schedule.lastRun?.outcome, .sent, "an outcome from a newer runner reads as sent, not as a failure")
    }

    func testListSkipsSchedulesThatDontDecode() throws {
        let json = #"{"schedules":[{"id":"a","text":"one"},{"title":"no id"},{"id":"b","text":"two"}]}"#
        let result = try JSONDecoder().decode(SchedulesResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.schedules.map(\.id), ["a", "b"])
    }

    func testPreviewDecodesRuns() throws {
        let json = #"{"whenText":"Weekdays at 9:00","runs":["2026-10-28T01:00:00Z","not a date","2026-10-29T01:00:00Z"]}"#
        let preview = try JSONDecoder().decode(SchedulePreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.whenText, "Weekdays at 9:00")
        XCTAssertEqual(preview.runs.count, 2)
    }

    func testSchedulesUpdatedNotification() async throws {
        let transport = FakeTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        transport.push(E.json(["jsonrpc": "2.0", "method": "schedules.updated",
                               "params": ["schedules": [["id": "sc1", "text": "hi", "whenText": "Every hour", "cron": "0 * * * *"]]]]))
        var iterator = client.notifications.makeAsyncIterator()
        guard case .schedulesUpdated(let list)? = await iterator.next() else { return XCTFail("no schedules.updated") }
        XCTAssertEqual(list.map(\.id), ["sc1"])
        XCTAssertEqual(list.first?.whenText, "Every hour")
    }

    // MARK: Requests

    func testCreateParamsLeaveNewThreadSettingsOutForAThread() {
        let at = ISO8601.parse("2026-10-28T01:00:00Z")!
        let forThread = NewScheduleRequest(text: "hi", when: .at(at), threadId: "th1", cwd: "/x", accountId: "claude-3").params
        XCTAssertEqual(forThread["threadId"], .string("th1"))
        XCTAssertEqual(forThread["at"], .string(ISO8601.format(at)))
        XCTAssertNil(forThread["cwd"])
        XCTAssertNil(forThread["accountId"])
        XCTAssertNil(forThread["cron"])
        let fresh = NewScheduleRequest(text: "hi", title: "T", when: .cron("0 9 * * *"), cwd: "/x", accountId: "claude-3", permissionMode: .ask).params
        XCTAssertEqual(fresh["cron"], .string("0 9 * * *"))
        XCTAssertEqual(fresh["cwd"], .string("/x"))
        XCTAssertEqual(fresh["permissionMode"], .string("ask"))
        XCTAssertEqual(fresh["title"], .string("T"))
        XCTAssertNil(fresh["threadId"])
    }

    func testUpdateParamsOnlyWhatChanged() {
        XCTAssertEqual(ScheduleUpdate(paused: true).params, ["paused": .bool(true)])
        let params = ScheduleUpdate(text: "new", when: .cron("0 * * * *")).params
        XCTAssertEqual(params["cron"], .string("0 * * * *"))
        XCTAssertEqual(params["text"], .string("new"))
        XCTAssertNil(params["at"])
    }

    // MARK: Presets

    func testPresetsBuildCron() {
        XCTAssertEqual(RepeatChoice(kind: .hourly).cron, "0 * * * *")
        XCTAssertEqual(RepeatChoice(kind: .daily, hour: 7, minute: 30).cron, "30 7 * * *")
        XCTAssertEqual(RepeatChoice(kind: .weekdays, hour: 9, minute: 0).cron, "0 9 * * 1-5")
        XCTAssertEqual(RepeatChoice(kind: .weekly, hour: 17, minute: 5, weekday: 5).cron, "5 17 * * 5")
        XCTAssertEqual(RepeatChoice(kind: .monthly, hour: 8, minute: 0, day: 15).cron, "0 8 15 * *")
        XCTAssertEqual(RepeatChoice(kind: .custom, custom: "  */15 9-17 * * *\n").cron, "*/15 9-17 * * *")
    }

    func testCronReadsBackAsItsPreset() {
        for choice in [
            RepeatChoice(kind: .hourly), RepeatChoice(kind: .daily, hour: 7, minute: 30),
            RepeatChoice(kind: .weekdays, hour: 9, minute: 0), RepeatChoice(kind: .weekly, hour: 17, minute: 5, weekday: 0),
            RepeatChoice(kind: .monthly, hour: 8, minute: 0, day: 31),
        ] {
            let back = RepeatChoice(cron: choice.cron)
            XCTAssertEqual(back.kind, choice.kind, choice.cron)
            XCTAssertEqual(back.cron, choice.cron)
        }
        XCTAssertEqual(RepeatChoice(cron: "0 9 * * 7").weekday, 0, "7 is Sunday too")
        for other in ["*/15 * * * *", "0 9-17 * * *", "0 9 1 * 1", "0 9 * 6 *", "@daily", "30 * * * *", "0 9 * * mon", "nonsense"] {
            let choice = RepeatChoice(cron: other)
            XCTAssertEqual(choice.kind, .custom, other)
            XCTAssertEqual(choice.cron, other, "a custom cron is kept as it was")
        }
    }

    // MARK: Words

    func testRelativeNextRun() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ seconds: TimeInterval) -> String { ScheduleTime.relative(now.addingTimeInterval(seconds), now: now) }
        XCTAssertEqual(text(-30), "now")
        XCTAssertEqual(text(0), "now")
        XCTAssertEqual(text(20), "in 1m")
        XCTAssertEqual(text(12 * 60), "in 12m")
        XCTAssertEqual(text(59 * 60 + 30), "in 1h")
        XCTAssertEqual(text(3 * 3600 + 10 * 60), "in 3h")
        XCTAssertEqual(text(3 * 3600 + 40 * 60), "in 4h")
        XCTAssertEqual(text(23 * 3600), "in 23h")
        XCTAssertEqual(text(26 * 3600), "in 1 day")
        XCTAssertEqual(text(6 * 86_400 + 3600), "in 6 days")
        XCTAssertEqual(ScheduleTime.next(now.addingTimeInterval(3 * 3600), now: now), "next in 3h")
        XCTAssertEqual(ScheduleTime.next(now.addingTimeInterval(-5), now: now), "due now")
    }

    func testDefaultOnceIsAWholeHourAtLeastAQuarterAway() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = { (text: String) in ISO8601.parse(text)! }
        XCTAssertEqual(ScheduleTime.defaultOnce(now: at("2026-10-27T10:20:00Z"), calendar: calendar), at("2026-10-27T11:00:00Z"))
        XCTAssertEqual(ScheduleTime.defaultOnce(now: at("2026-10-27T10:50:00Z"), calendar: calendar), at("2026-10-27T12:00:00Z"))
        XCTAssertEqual(ScheduleTime.defaultOnce(now: at("2026-10-27T10:45:00Z"), calendar: calendar), at("2026-10-27T11:00:00Z"))
    }

    func testComposerLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = Schedule(id: "a", title: "A", whenText: "Weekdays at 9:00", threadId: "th1", nextRunAt: now.addingTimeInterval(3 * 3600))
        let later = Schedule(id: "b", title: "B", whenText: "Mondays at 10:00", createdBy: "th1", nextRunAt: now.addingTimeInterval(30 * 3600))
        let paused = Schedule(id: "c", title: "C", whenText: "Every hour", threadId: "th1", paused: true)
        let elsewhere = Schedule(id: "d", title: "D", whenText: "Every day at 2:00", threadId: "th2", nextRunAt: now.addingTimeInterval(60))
        XCTAssertNil(ScheduleLine.line(for: "th1", in: [paused, elsewhere], now: now), "paused ones don't count")
        XCTAssertEqual(ScheduleLine.line(for: "th1", in: [soon, paused], now: now),
                       ScheduleLine.Line(text: "Scheduled: Weekdays at 9:00 · next in 3h", scheduleId: "a"))
        XCTAssertEqual(ScheduleLine.line(for: "th1", in: [later, soon, elsewhere], now: now),
                       ScheduleLine.Line(text: "2 schedules · next in 3h", scheduleId: nil))
    }

    // MARK: The transcript

    func testScheduledHeader() throws {
        let header = try XCTUnwrap(ScheduledHeader("[Scheduled: \"Check \"prod\", again\", Once, Tue 28 Oct at 15:30]\nIs it up?\nSay so."))
        XCTAssertEqual(header.title, "Check \"prod\", again")
        XCTAssertEqual(header.whenText, "Once, Tue 28 Oct at 15:30")
        XCTAssertEqual(header.body, "Is it up?\nSay so.")
        XCTAssertNil(ScheduledHeader("Just a message"))
        XCTAssertNil(ScheduledHeader("[Scheduled: no quotes]"))
        XCTAssertEqual(ScheduledHeader("[Scheduled: \"T\", Every hour]")?.body, "")
    }

    func testScheduleMessagesAreNotes() {
        let event = E.event(1, "user.message", ["text": "[Scheduled: \"T\", Every hour]\nGo.", "images": [], "origin": "schedule", "scheduleId": "sc1"])
        let model = TranscriptModel(events: [event])
        guard case .user(let message)? = model.items.first?.content else { return XCTFail("no message") }
        XCTAssertTrue(message.isFromSchedule)
        XCTAssertFalse(message.isFromRunner)
        XCTAssertTrue(message.showsAsNote)
        XCTAssertEqual(message.scheduledHeader?.title, "T")
        XCTAssertFalse(UserMessage(text: "[Scheduled: \"T\", Every hour]").showsAsNote, "Mike typing the header is still Mike")
        XCTAssertNil(UserMessage(text: "[Scheduled: \"T\", Every hour]").scheduledHeader)
    }

    func testAgentHeader() throws {
        let header = try XCTUnwrap(AgentHeader("[Sent by the agent in the thread \"Mobile app for \"Threadbare\" (v2)\" (f5247e5b)]\n\nFrom f5247e5b: hi.\nBye."))
        XCTAssertEqual(header.title, "Mobile app for \"Threadbare\" (v2)")
        XCTAssertEqual(header.threadId, "f5247e5b")
        XCTAssertEqual(header.body, "From f5247e5b: hi.\nBye.")
        XCTAssertNil(AgentHeader("Just a message"))
        XCTAssertNil(AgentHeader("[Sent by the agent in the thread X]"))
        XCTAssertNotNil(UserMessage(text: "[Sent by the agent in the thread \"T\" (12345678)]\n\nGo.").agentHeader)
        XCTAssertNil(UserMessage(text: "[Sent by the agent in the thread \"T\" (12345678)]", origin: "phone").agentHeader)
        XCTAssertFalse(UserMessage(text: "[Sent by the agent in the thread \"T\" (12345678)]").showsAsNote)
        XCTAssertNil(header.movedTo)
    }

    func testMoveThenHeader() throws {
        let header = try XCTUnwrap(AgentHeader("[Sent by the agent before moving to /Users/m/dev/threadbear]\n\nCarry on with the tests."))
        XCTAssertEqual(header.movedTo, "/Users/m/dev/threadbear")
        XCTAssertEqual(header.threadId, "")
        XCTAssertEqual(header.body, "Carry on with the tests.")
        XCTAssertNotNil(UserMessage(text: "[Sent by the agent before moving to /tmp]\n\nGo.").agentHeader)
        XCTAssertNil(UserMessage(text: "[Sent by the agent before moving to /tmp]\n\nGo.", origin: "phone").agentHeader)
        XCTAssertNil(AgentHeader("[Sent by the agent before moving to ]"))
        XCTAssertNil(AgentHeader("[Sent by the agent before moving to /tmp"))
    }

    func testStartedByScheduleTip() {
        let origin = ThreadSchedule(id: "sc1", title: "Quarterly invoice export")
        let live = Schedule(id: "sc1", title: "Invoices", whenText: "Weekdays at 9:00")
        XCTAssertEqual(StartedBySchedule.tip(origin, current: live), "Started by a schedule: Quarterly invoice export (Weekdays at 9:00). Click to edit it.")
        XCTAssertEqual(StartedBySchedule.tip(origin, current: Schedule(id: "sc1", title: "x", whenText: "Every hour", paused: true)),
                       "Started by a schedule: Quarterly invoice export (paused). Click to edit it.")
        XCTAssertEqual(StartedBySchedule.tip(origin, current: nil), "Started by a schedule: Quarterly invoice export. It has since been deleted.")
    }

    func testThreadSummaryScheduleDecodesLeniently() throws {
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"t1","title":"x","schedule":{"id":"sc1","title":"Daily brief","later":1}}"#.utf8))
        XCTAssertEqual(thread.schedule, ThreadSchedule(id: "sc1", title: "Daily brief"))
        XCTAssertEqual(try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread)).schedule, thread.schedule)
        XCTAssertNil(try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"t1"}"#.utf8)).schedule)
        // A malformed one is dropped rather than losing the thread.
        XCTAssertNil(try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"t1","schedule":"sc1"}"#.utf8)).schedule)
    }
}
