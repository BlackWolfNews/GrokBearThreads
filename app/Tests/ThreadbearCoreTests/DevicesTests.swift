import XCTest
@testable import ThreadbearCore

/// Settings › Phone & browser's types (docs/protocol.md, "Devices"): what
/// the runner's replies decode to, forgiving of what an older or newer
/// runner leaves out or adds.
final class DevicesTests: XCTestCase {
    func testListDecodesDevicesSiteAndReason() throws {
        let json = """
        {"devices":[
          {"id":"a","kind":"phone","name":"iPhone","createdAt":"2026-10-28T10:00:00.000Z","expiresAt":"2027-01-26T10:00:00.000Z","expired":false},
          {"id":"b","kind":"browser","name":"Chrome","createdAt":"2026-10-28T10:00:00.000Z","expiresAt":"2026-10-27T10:00:00.000Z","expired":true},
          {"id":"c","kind":"watch","name":"Watch"},
          {"kind":"phone","name":"no id, skipped"}
        ],"site":"https://x.convex.site"}
        """
        let list = try JSONDecoder().decode(DeviceList.self, from: Data(json.utf8))
        XCTAssertEqual(list.devices.map(\.id), ["a", "b", "c"], "a row with no id is dropped, not the whole list")
        XCTAssertEqual(list.devices[0].kind, .phone)
        XCTAssertEqual(list.devices[1].kind, .browser)
        XCTAssertTrue(list.devices[1].expired)
        XCTAssertEqual(list.devices[2].kind, .other, "a kind from a newer runner")
        XCTAssertNil(list.devices[2].expiresAt)
        XCTAssertEqual(list.site, "https://x.convex.site")
        XCTAssertNil(list.reason)

        let off = try JSONDecoder().decode(DeviceList.self, from: Data(#"{"devices":[],"reason":"no sync.url in runner.json"}"#.utf8))
        XCTAssertEqual(off.devices, [])
        XCTAssertEqual(off.reason, "no sync.url in runner.json")
        XCTAssertNil(off.site)
    }

    func testPairingDecodesEitherLink() throws {
        let phone = try JSONDecoder().decode(DevicePairing.self, from: Data(#"{"device":{"id":"a","kind":"phone","name":"iPhone"},"pairingLink":"threadbear://pair?url=https%3A%2F%2Fx.convex.cloud&token=tb_1"}"#.utf8))
        XCTAssertEqual(phone.pairingLink?.scheme, "threadbear")
        XCTAssertNil(phone.signInLink)
        let browser = try JSONDecoder().decode(DevicePairing.self, from: Data(#"{"device":{"id":"b","kind":"browser","name":"Chrome"},"signInLink":"https://x.convex.site/#token=tb_2"}"#.utf8))
        XCTAssertEqual(browser.signInLink?.fragment, "token=tb_2")
        XCTAssertNil(browser.pairingLink)
    }

    func testDetailLineSaysWhenPairedAndUntilWhen() throws {
        let now = ISO8601.parse("2026-10-28T12:00:00.000Z")!
        let calendar = Calendar(identifier: .gregorian)
        let live = Device(id: "a", kind: .phone, name: "iPhone", createdAt: ISO8601.parse("2026-10-21T09:12:00.000Z"), expiresAt: ISO8601.parse("2027-01-19T09:12:00.000Z"))
        XCTAssertEqual(DeviceText.detail(live, now: now, calendar: calendar), "Paired 21 Oct, until 19 Jan 2027")
        let expired = Device(id: "b", kind: .browser, name: "Safari", createdAt: ISO8601.parse("2026-07-01T08:00:00.000Z"), expiresAt: ISO8601.parse("2026-09-29T08:00:00.000Z"), expired: true)
        XCTAssertEqual(DeviceText.detail(expired, now: now, calendar: calendar), "Expired 29 Sep: pair it again")
        let bare = Device(id: "c", kind: .other, name: "Watch")
        XCTAssertEqual(DeviceText.detail(bare, now: now, calendar: calendar), "")
    }
}
