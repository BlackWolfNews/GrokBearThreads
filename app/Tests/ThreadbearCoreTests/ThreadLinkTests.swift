import Foundation
import XCTest
@testable import ThreadbearCore

final class ThreadLinkTests: XCTestCase {
    func testReadsTheThreadIdBack() {
        let url = ThreadLink.url(threadId: "6309da76-d0c5-49a1-bddf-9820bf6124dc")!
        XCTAssertEqual(url.absoluteString, "threadbear://thread/6309da76-d0c5-49a1-bddf-9820bf6124dc")
        XCTAssertEqual(ThreadLink.threadId(from: url), "6309da76-d0c5-49a1-bddf-9820bf6124dc")
    }

    func testIgnoresOtherLinks() {
        for link in ["threadbear://pair?url=x&token=y", "threadbear://thread/", "threadbear://thread/../etc", "https://thread/abc", "threadbear://thread/a%20b"] {
            XCTAssertNil(ThreadLink.threadId(from: URL(string: link)!), link)
        }
    }
}
