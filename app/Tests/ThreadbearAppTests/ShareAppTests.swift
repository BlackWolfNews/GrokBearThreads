import XCTest
@testable import Threadbear
import ThreadbearCore

/// The share button and popover's words (ShareButton.swift).
final class ShareAppTests: XCTestCase {
    func testEmailsTypedIntoTheField() {
        let r = ShareText.emails(in: " Ann@Example.com, bo@example.org;<cy@example.net>  nope ")
        XCTAssertEqual(r.valid, ["ann@example.com", "bo@example.org", "cy@example.net"])
        XCTAssertEqual(r.invalid, ["nope"])
        XCTAssertEqual(ShareText.emails(in: "  ").valid, [])
    }

    func testButtonTipSaysWhoCanRead() {
        func tip(_ share: ThreadShare?) -> String { ShareText.buttonTip(ThreadSummary(id: "t", title: "T", share: share)) }
        XCTAssertEqual(tip(nil), "Share this thread on the web")
        XCTAssertEqual(tip(ThreadShare(access: .off, slug: "s")), "Share this thread on the web")
        XCTAssertEqual(tip(ThreadShare(access: .link, slug: "s")), "Shared: anyone with the link can read it")
        XCTAssertEqual(tip(ThreadShare(access: .people, slug: "s", people: ["ann@example.com"])), "Shared with ann@example.com")
        XCTAssertEqual(tip(ThreadShare(access: .people, slug: "s", people: ["a@x.io", "b@x.io"])), "Shared with 2 people")
    }
}
