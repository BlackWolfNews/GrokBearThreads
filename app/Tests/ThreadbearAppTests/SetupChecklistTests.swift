import XCTest
import ThreadbearCore
@testable import Threadbear

/// Finish setting up ticks itself off from what the app knows, and leaves
/// out what this install can't do.
final class SetupChecklistTests: XCTestCase {
    private func thread(_ id: String, session: String?, status: ThreadStatus = .idle) -> ThreadSummary {
        var t = ThreadSummary(id: id, title: "", cwd: "/tmp", accountId: "a")
        t.nativeSessionId = session
        t.status = status
        return t
    }

    private let account = Account(id: "a", title: "a")

    func testNewInstallHasEverythingLeft() {
        let list = SetupChecklist.build(threads: [], accounts: [account], devices: [], canPair: true, notifications: .notAsked)
        XCTAssertEqual(list.items.map(\.item), [.firstThread, .notifications, .phone, .website])
        XCTAssertEqual(list.left, 4)
        XCTAssertFalse(list.noLogin)
    }

    func testEachTicksItselfOff() {
        let devices = [Device(id: "1", kind: .phone, name: "iPhone"), Device(id: "2", kind: .browser, name: "Chrome")]
        let list = SetupChecklist.build(threads: [thread("t", session: "s")], accounts: [account], devices: devices,
                                        canPair: true, notifications: .allowed)
        XCTAssertEqual(list.left, 0)
    }

    func testAFailedOrUnstartedThreadDoesntCount() {
        for t in [thread("t", session: nil), thread("t", session: "s", status: .error)] {
            let list = SetupChecklist.build(threads: [t], accounts: [account], devices: [], canPair: false, notifications: .allowed)
            XCTAssertEqual(list.items.first?.done, false)
        }
    }

    func testAnExpiredPhoneNeedsPairingAgain() {
        let list = SetupChecklist.build(threads: [], accounts: [account], devices: [Device(id: "1", kind: .phone, name: "iPhone", expired: true)],
                                        canPair: true, notifications: .denied)
        XCTAssertEqual(list.items.first { $0.item == .phone }?.done, false)
    }

    func testWithoutTheMirrorThePhoneAndWebsiteArentListed() {
        let list = SetupChecklist.build(threads: [], accounts: [], devices: [], canPair: false, notifications: .notAsked)
        XCTAssertEqual(list.items.map(\.item), [.firstThread, .notifications])
        XCTAssertTrue(list.noLogin)
    }
}
