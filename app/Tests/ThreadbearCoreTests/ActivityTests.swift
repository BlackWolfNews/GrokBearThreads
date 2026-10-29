import XCTest
@testable import ThreadbearCore

final class ActivityTests: XCTestCase {
    /// A line has what was set and nothing else, and reads back the same.
    func testLineRoundTrips() throws {
        var event = ActivityEvent(kind: .click, at: Date(timeIntervalSince1970: 1_793_239_331.5))
        event.target = "Archive (⌘E)"
        event.button = "right"
        event.thread = "2072de5b-8d67-48d5-b814-2c8eb26e5eb4"
        let line = try event.line()
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["at", "kind", "target", "button", "thread"])
        XCTAssertEqual(object["kind"] as? String, "click")
        // Local time, with the offset written the way JavaScript reads it.
        let at = try XCTUnwrap(object["at"] as? String)
        XCTAssertNotNil(at.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression), at)
        let back = try ActivityEvent.parse(line)
        XCTAssertEqual(back.kind, .click)
        XCTAssertEqual(back.target, "Archive (⌘E)")
        XCTAssertEqual(back.at.timeIntervalSince1970, 1_793_239_331.5, accuracy: 0.001)
    }

    func testLabelIsTheFirstLineAndShort() {
        XCTAssertEqual(ActivityEvent.label("Fix the sidebar\n~/dev/me/threadbear"), "Fix the sidebar")
        XCTAssertNil(ActivityEvent.label("  \n"))
        let long = ActivityEvent.label(String(repeating: "a", count: 300))
        XCTAssertEqual(long?.count, 120)
        XCTAssertEqual(long?.last, "…")
    }

    func testFileNamesAreLocalDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        // 20:30 UTC on 28 Oct is 04:30 on the 29th in Perth.
        let date = Date(timeIntervalSince1970: 1_793_219_400)
        XCTAssertEqual(ActivityFiles.fileName(for: date, calendar: calendar), "2026-10-29.jsonl")
    }

    /// The last 30 days are kept, and nothing that isn't a day file is
    /// touched.
    func testExpiredFiles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9))!
        let names = ["2026-09-28.jsonl", "2026-09-29.jsonl", "2026-10-29.jsonl", "2025-12-31.jsonl", "notes.txt", "2026-09-01.jsonl.tmp"]
        XCTAssertEqual(ActivityFiles.expired(names, now: now, calendar: calendar), ["2026-09-28.jsonl", "2025-12-31.jsonl"])
    }

    /// Shortcuts are recorded by name; typing never is, not even with ⌥ or
    /// ⇧ held, and Escape is the one bare key that is.
    func testOnlyShortcutsAreRecorded() {
        func key(_ code: UInt16, _ chars: String?, cmd: Bool = false, ctrl: Bool = false, opt: Bool = false, shift: Bool = false) -> String? {
            ActivityKeys.shortcut(keyCode: code, characters: chars, command: cmd, control: ctrl, option: opt, shift: shift)
        }
        XCTAssertEqual(key(45, "n", cmd: true), "⌘N")
        XCTAssertEqual(key(35, "p", cmd: true, opt: true), "⌥⌘P")
        XCTAssertEqual(key(8, "C", cmd: true, shift: true), "⇧⌘C")
        XCTAssertEqual(key(1, "s", cmd: true, ctrl: true), "⌃⌘S")
        XCTAssertEqual(key(36, "\r", cmd: true), "⌘↩")
        XCTAssertEqual(key(33, "[", cmd: true), "⌘[")
        XCTAssertEqual(key(53, "\u{1b}"), "Esc")
        XCTAssertNil(key(0, "a"))
        XCTAssertNil(key(0, "A", shift: true))
        XCTAssertNil(key(14, "e", opt: true))
        XCTAssertNil(key(36, "\r"))
        XCTAssertNil(key(51, "\u{7f}"))
        XCTAssertNil(key(125, nil))
    }
}
