import XCTest
@testable import ThreadbearCore

/// The Usage panel's groups (pools, then providers within each) and the
/// short tooltips on the activity bar's Usage and Updates icons.
final class UsageGroupsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    private var now: Date { at(10) }

    private func at(day: Int = 28, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func login(_ id: String, _ provider: String = "claude", five: Double? = nil, week: Double, blocked: Bool = false, reset: Date? = nil) -> Account {
        var windows: [UsageWindow] = []
        if let five { windows.append(UsageWindow(kind: "five_hour", title: "5-hour", remainingPercent: five, resetsAt: reset)) }
        windows.append(UsageWindow(kind: "weekly", title: "Weekly", remainingPercent: week))
        return Account(id: id, provider: provider, title: id, usage: AccountUsage(windows: windows, blocked: blocked))
    }

    func testGroupsByPoolThenProviderInThePoolsOrder() {
        let accounts = [login("c1", five: 90, week: 80), login("c2", five: 50, week: 40), login("x1", "codex", week: 70), login("c3", week: 10)]
        let pools = [
            Pool(id: "mixed", title: "Mixed", accountIds: ["x1", "c2"]),
            Pool(id: "claude", title: "Claude", accountIds: ["c1", "c2"]),
        ]
        let groups = UsageGroups.build(pools: pools, accounts: accounts)
        XCTAssertEqual(groups.map(\.title), ["Mixed", "Claude", "Not in a pool"])
        // The pool's order decides which provider comes first.
        XCTAssertEqual(groups[0].providers.map(\.provider), ["codex", "claude"])
        XCTAssertEqual(groups[1].accounts.map(\.id), ["c1", "c2"])
        XCTAssertEqual(groups[2].accounts.map(\.id), ["c3"])
    }

    func testWithoutPoolsEachProviderIsAGroupClaudeFirst() {
        let accounts = [login("x1", "codex", week: 70), login("c1", week: 80)]
        let groups = UsageGroups.build(pools: [], accounts: accounts)
        XCTAssertEqual(groups.map(\.title), ["Claude", "Codex"])
        XCTAssertNil(groups[0].pool)
    }

    func testAPoolWithNoLoginsWeKnowIsLeftOut() {
        let groups = UsageGroups.build(pools: [Pool(id: "gone", title: "Gone", accountIds: ["nobody"])], accounts: [login("c1", week: 50)])
        XCTAssertEqual(groups.map(\.title), ["Not in a pool"])
    }

    func testUsageTooltipSaysEachPoolsBestRoom() {
        let groups = UsageGroups.build(pools: [
            Pool(id: "claude", title: "Claude", accountIds: ["c1", "c2"]),
            Pool(id: "codex", title: "Codex", accountIds: ["x1"]),
        ], accounts: [login("c1", five: 94, week: 93), login("c2", five: 100, week: 16), login("x1", "codex", week: 79)])
        XCTAssertEqual(UsageGroups.tooltip(groups, now: now, calendar: calendar), "Usage\nClaude: 93% left\nCodex: 79% left")
    }

    func testUsageTooltipSaysWhenAPoolAtItsLimitComesBack() {
        let groups = UsageGroups.build(pools: [Pool(id: "claude", title: "Claude", accountIds: ["c1", "c2"])], accounts: [
            login("c1", five: 0, week: 50, blocked: true, reset: at(13, 26)),
            login("c2", five: 0, week: 40, blocked: true, reset: at(12, 56)),
        ])
        XCTAssertEqual(UsageGroups.tooltip(groups, now: now, calendar: calendar), "Usage\nClaude: at its limit, back at 12:56 pm")
    }

    func testUpdatesTooltipListsWhatsGoingOn() {
        let side = UpdatesText.AppSide(running: "abc1234")
        let current = CliStatus(provider: "claude", installedVersion: "2.1.312", latestVersion: "2.1.312", status: "current")
        XCTAssertEqual(UpdatesText.iconTooltip(app: side, runner: RunnerUpdates(state: "idle"), clis: [current]), "Updates\nEverything is up to date")
        let behind = CliStatus(provider: "claude", installedVersion: "2.1.311", latestVersion: "2.1.312", status: "behind")
        XCTAssertEqual(UpdatesText.iconTooltip(app: UpdatesText.AppSide(staged: "def5678"), runner: nil, clis: [behind]),
                       "Updates\nAn app update\nClaude Code 2.1.311, 2.1.312 available")
        XCTAssertFalse(UpdatesText.cliPending(current))
        XCTAssertTrue(UpdatesText.cliPending(behind))
    }
}
