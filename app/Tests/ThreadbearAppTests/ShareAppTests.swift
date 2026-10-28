import XCTest
@testable import Threadbear
import ThreadbearCore

/// The share button's words (ShareButton.swift).
final class ShareAppTests: XCTestCase {
    func testButtonTipSaysWhetherItsShared() {
        func tip(_ share: ThreadShare?) -> String { ShareText.buttonTip(ThreadSummary(id: "t", title: "T", share: share)) }
        XCTAssertEqual(tip(nil), "Share this thread on the web")
        XCTAssertEqual(tip(ThreadShare(access: .off, slug: "s")), "Share this thread on the web")
        XCTAssertEqual(tip(ThreadShare(access: .link, slug: "s")), "Shared: anyone with the link can read it")
    }
}
