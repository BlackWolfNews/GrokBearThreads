import Foundation
import XCTest
@testable import ThreadbareCore

final class AccountUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    /// Tuesday 27 Oct 2026, 10:00 in Perth.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10, minute: 0))!
    }

    private func at(day: Int = 27, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: pickAccount, the same cases as the runner

    private struct Cases: Decodable {
        struct Case: Decodable {
            var name: String
            var lastUsedId: String?
            var accounts: [Short]
            var expected: String?
        }

        struct Short: Decodable {
            var id: String
            var provider: String
            var note: String?
            var blocked: Bool?
            var windows: [[JSONValue]]?
        }

        var cases: [Case]
    }

    private static var casesURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/pick-account-cases.json")
    }

    func testPickAccountMatchesTheRunnersCases() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: Self.casesURL)).cases
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let accounts = c.accounts.map { short -> Account in
                let windows = (short.windows ?? []).compactMap { pair -> UsageWindow? in
                    guard pair.count == 2, let kind = pair[0].stringValue, let percent = pair[1].doubleValue else { return nil }
                    return UsageWindow(kind: kind, title: kind, remainingPercent: percent)
                }
                let usage = short.windows == nil && short.blocked == nil ? nil : AccountUsage(windows: windows, blocked: short.blocked ?? false)
                return Account(id: short.id, provider: short.provider, title: short.id, note: short.note, usage: usage)
            }
            XCTAssertEqual(AccountUsageText.pickAccount(accounts, lastUsedId: c.lastUsedId), c.expected, c.name)
        }
    }

    /// The copy here is the runner's file; once both are in one tree, they
    /// must be the same bytes.
    func testCasesAreTheRunnersCopy() throws {
        let runner = Self.casesURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("runner/test/fixtures/pick-account-cases.json")
        guard FileManager.default.fileExists(atPath: runner.path) else { throw XCTSkip("the runner's copy isn't in this tree yet") }
        XCTAssertEqual(try Data(contentsOf: runner), try Data(contentsOf: Self.casesURL),
                       "app/Tests/Fixtures/pick-account-cases.json differs from runner/test/fixtures: copy the runner's over")
    }

    // MARK: Words

    private func usage(_ fiveHour: Double?, _ weekly: Double?, blocked: Bool = false, reset: Date? = nil, weeklyReset: Date? = nil) -> AccountUsage {
        var windows: [UsageWindow] = []
        if let fiveHour { windows.append(UsageWindow(kind: "five_hour", title: "5-hour", remainingPercent: fiveHour, resetsAt: reset)) }
        if let weekly { windows.append(UsageWindow(kind: "weekly", title: "Weekly", remainingPercent: weekly, resetsAt: weeklyReset)) }
        return AccountUsage(windows: windows, blocked: blocked)
    }

    func testMenuLine() {
        let u = usage(89, 78, reset: at(15, 40), weeklyReset: at(day: 29, 13))
        // The reset is the tighter window's.
        XCTAssertEqual(AccountUsageText.menuLine(u, now: now, calendar: calendar), "5h 89% · week 78%, resets Thu 1 pm")
        let tight5h = usage(12, 78, reset: at(15, 40), weeklyReset: at(day: 29, 13))
        XCTAssertEqual(AccountUsageText.menuLine(tight5h, now: now, calendar: calendar), "5h 12% · week 78%, resets 3:40 pm")
        let blocked = usage(0, 31, blocked: true, reset: at(15, 40))
        XCTAssertEqual(AccountUsageText.menuLine(blocked, now: now, calendar: calendar), "Limit reached, resets 3:40 pm")
        // Pro Lite: weekly only.
        XCTAssertEqual(AccountUsageText.menuLine(usage(nil, 64), now: now, calendar: calendar), "week 64%")
        XCTAssertNil(AccountUsageText.menuLine(nil, now: now, calendar: calendar))
        XCTAssertNil(AccountUsageText.menuLine(AccountUsage(windows: [UsageWindow(kind: "allowance", title: "$250 allowance", remainingPercent: 53.1)]), now: now))
    }

    func testSubtitleHasTheNoteFirst() {
        let account = Account(id: "claude-2", title: "work@example.com", note: "Convex work only", usage: usage(95, 90, reset: at(12, 5), weeklyReset: at(day: 30, 9)))
        XCTAssertEqual(AccountUsageText.subtitle(account, now: now, calendar: calendar), "Convex work only · 5h 95% · week 90%, resets Fri 9 am")
        XCTAssertNil(AccountUsageText.subtitle(Account(id: "x", title: "x"), now: now))
    }

    func testResetTimes() {
        XCTAssertEqual(AccountUsageText.resetTime(at(15, 40), now: now, calendar: calendar), "3:40 pm")
        XCTAssertEqual(AccountUsageText.resetTime(at(day: 28, 9), now: now, calendar: calendar), "tomorrow 9 am")
        XCTAssertEqual(AccountUsageText.resetTime(at(day: 29, 0, 30), now: now, calendar: calendar), "Thu 12:30 am")
        XCTAssertEqual(AccountUsageText.resetTime(at(day: 12, 9).addingTimeInterval(30 * 86_400), now: now, calendar: calendar), "11 Nov")
        XCTAssertEqual(AccountUsageText.resetTime(at(9), now: now, calendar: calendar), "now")
        XCTAssertEqual(AccountUsageText.clock(at(12, 0), calendar: calendar), "12 pm")
    }

    func testChipBadge() {
        XCTAssertNil(AccountUsageText.chipBadge(usage(89, 78)))
        XCTAssertEqual(AccountUsageText.chipBadge(usage(12, 40)), .low("12%"))
        XCTAssertEqual(AccountUsageText.chipBadge(usage(24.9, 40)), .low("24%"))
        XCTAssertNil(AccountUsageText.chipBadge(usage(25, 40)))
        XCTAssertEqual(AccountUsageText.chipBadge(usage(0, 40, blocked: true)), .blocked)
        XCTAssertNil(AccountUsageText.chipBadge(nil), "an older runner sends no usage")
    }

    func testTooltip() {
        let account = Account(id: "claude-main", title: "mike@example.com", email: "mike@example.com", usage: usage(89, 78, reset: at(15, 40), weeklyReset: at(day: 29, 13)))
        XCTAssertEqual(AccountUsageText.tooltip(account, fallback: "claude-main", now: now, calendar: calendar),
                       "mike@example.com: 5-hour 89% left, Weekly 78% left, resets Thu 1 pm.")
        XCTAssertEqual(AccountUsageText.tooltip(nil, fallback: "claude-9", now: now), "claude-9")
    }

    func testSourceLine() {
        func reading(_ date: Date, stale: Bool = false, source: String = "tokenStats") -> Account {
            Account(id: UUID().uuidString, title: "a", usage: AccountUsage(windows: [], readAt: date, source: source, stale: stale))
        }
        XCTAssertEqual(AccountUsageText.sourceLine([reading(at(7, 15)), reading(at(6, 2))], now: now, calendar: calendar), "Usage from Token Stats at 7:15 am")
        XCTAssertEqual(AccountUsageText.sourceLine([reading(at(6, 2), stale: true)], now: now, calendar: calendar), "Token Stats hasn't updated since 6:02 am")
        // One fresh reading is enough for "from Token Stats".
        XCTAssertEqual(AccountUsageText.sourceLine([reading(at(6, 2), stale: true), reading(at(7, 15))], now: now, calendar: calendar), "Usage from Token Stats at 7:15 am")
        XCTAssertNil(AccountUsageText.sourceLine([reading(at(9), source: "live")], now: now))
        XCTAssertNil(AccountUsageText.sourceLine([], now: now))
    }

    func testExtraWindowsLeaveOutTheMainOnes() {
        let u = AccountUsage(windows: [
            UsageWindow(kind: "five_hour", title: "5-hour", remainingPercent: 89),
            UsageWindow(kind: "weekly_model", title: "Weekly Fable", remainingPercent: 71),
            UsageWindow(kind: "weekly", title: "Weekly", remainingPercent: 78),
        ])
        XCTAssertEqual(AccountUsageText.mainWindows(u).map(\.kind), ["five_hour", "weekly"])
        XCTAssertEqual(AccountUsageText.extraWindows(u).map(\.title), ["Weekly Fable"])
        XCTAssertEqual(AccountUsageText.room(u), 78)
    }

    func testSwitchTargetPrefersTheSameProvider() {
        let accounts = [
            Account(id: "claude-main", title: "mike@example.com", email: "mike@example.com", usage: usage(0, 50, blocked: true)),
            Account(id: "claude-2", title: "work@example.com", note: "Convex work only", usage: usage(99, 99)),
            Account(id: "claude-3", title: "mike+3@example.com", email: "mike+3@example.com", usage: usage(78, 80)),
            Account(id: "codex-main", provider: "codex", title: "Codex · mike@example.com", email: "mike@example.com", usage: usage(nil, 95)),
        ]
        let target = AccountUsageText.switchTarget(accounts, from: "claude-main")
        XCTAssertEqual(target?.id, "claude-3", "same provider first, never the noted account")
        XCTAssertEqual(target.map { AccountUsageText.switchTitle($0, accounts: accounts) }, "Switch to mike+3 (78% left)")
        // Nothing left on Codex: a Claude account.
        XCTAssertEqual(AccountUsageText.switchTarget(accounts, from: "codex-main")?.id, "claude-3")
        XCTAssertNil(AccountUsageText.switchTarget([accounts[0]], from: "claude-main"))
    }

    func testANoticeSeveralAccountsShareIsSaidOnce() {
        func with(_ id: String, _ notice: String?) -> Account {
            Account(id: id, title: id, usage: AccountUsage(windows: [], notice: notice))
        }
        let couldnt = "Couldn't check usage just now, so these are from 1:19 pm."
        let accounts = [
            with("claude-main", couldnt), with("claude-1", "\(couldnt) · $48.85 extra usage spent"), with("claude-3", couldnt),
            with("codex-main", "64,390 credits · 2 limit resets available"), with("claude-4", nil),
        ]
        let notices = AccountUsageText.notices(accounts)
        XCTAssertEqual(notices.shared, couldnt)
        XCTAssertEqual(notices.own, ["claude-1": "$48.85 extra usage spent", "codex-main": "64,390 credits · 2 limit resets available"])
        // One account's notice stays its own.
        XCTAssertEqual(AccountUsageText.notices([with("codex-main", "64,390 credits")]).own, ["codex-main": "64,390 credits"])
        XCTAssertNil(AccountUsageText.notices([with("codex-main", "64,390 credits")]).shared)
    }

    func testCreditsShowOnce() {
        let weekly = UsageWindow(kind: "weekly", title: "Weekly", remainingPercent: 93, detail: "64,390 credits")
        XCTAssertEqual(AccountUsageText.windowLine(weekly, now: now, notice: "64,390 credits · 2 limit resets available"), "93% left")
        XCTAssertEqual(AccountUsageText.windowLine(weekly, now: now), "93% left (64,390 credits)")
    }

    // MARK: Names

    func testAccountNamesAreProviderAware() {
        // claude-1 and codex-main share mike.cann@gmail.com, as Mike's do.
        let accounts = [
            Account(id: "claude-main", title: "mike@cannstudios.com", email: "mike@cannstudios.com"),
            Account(id: "claude-1", title: "mike.cann@gmail.com", email: "mike.cann@gmail.com"),
            Account(id: "codex-main", provider: "codex", title: "Codex · mike.cann@gmail.com", email: "mike.cann@gmail.com"),
        ]
        XCTAssertEqual(AccountName.short("claude-1", accounts: accounts), "mike.cann", "no clash across providers")
        XCTAssertEqual(AccountName.short("codex-main", accounts: accounts), "Codex")
        XCTAssertEqual(AccountName.title(accounts[2]), "mike.cann@gmail.com")
        // An older runner: no email, the title has the prefix.
        XCTAssertEqual(AccountName.title(Account(id: "codex-main", provider: "codex", title: "Codex · a@b.c")), "a@b.c")
        let two = accounts + [Account(id: "codex-1", provider: "codex", title: "Codex · m@work.example", email: "m@work.example")]
        XCTAssertEqual(AccountName.short("codex-main", accounts: two), "Codex mike.cann")
        XCTAssertEqual(AccountName.short("codex-1", accounts: two), "Codex m")
        // Codex rows are labelled, as any account other than main is.
        XCTAssertTrue(AccountName.isShown("codex-main", accounts: accounts, mainId: "claude-main"))
    }
}
