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

    /// What the ... menu's Share submenu opens and copies, and that it's
    /// not the public link: that one's `/s/<slug>`.
    @MainActor
    func testWebLinkIsTheThreadsOwnPageOnTheWebsite() {
        let app = AppModel()
        XCTAssertNil(app.threadWebLink("abc"), "no website while threads aren't mirrored, so no submenu")
        app.websiteURL = URL(string: "https://example.convex.site")
        XCTAssertEqual(app.threadWebLink("abc")?.absoluteString, "https://example.convex.site/t/abc")
    }
}
