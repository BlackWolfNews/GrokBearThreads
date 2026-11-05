import AppKit
import SwiftUI
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// The shelves of action chips on the composer show as many chips as fit
/// and the rest under "+N". They used to pick that with a ViewThatFits
/// over a whole row for every count, which builds every row it tries and
/// keeps one: about 65 chips for 10 actions, built again each time the
/// window asked the composer its size, which froze the app for 15 seconds
/// (5 Nov, THREADBEAR-Y).
@MainActor
final class ActionChipsTests: XCTestCase {
    private func thread(_ count: Int) throws -> ThreadSummary {
        var thread = ThreadSummary(id: "t", title: "T", status: .idle)
        let json = "[" + (1...count).map { #"{"id":"p:a\#($0)","title":"Action number \#($0)","kind":"command","command":"x","patch":"p\#($0 % 3)"}"# }.joined(separator: ",") + "]"
        thread.actions = try JSONDecoder().decode([Action].self, from: Data(json.utf8))
        return thread
    }

    private func host(_ thread: ThreadSummary, width: CGFloat) -> NSHostingView<AnyView> {
        let app = AppModel()
        let host = NSHostingView(rootView: AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ActionChips(thread: thread)
                Text("The message box")
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .environment(app)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        return host
    }

    /// Each chip is built a few times at most, however narrow the room,
    /// not once for every count of chips that might fit.
    func testEachChipIsBuiltAFewTimesNotOncePerCount() throws {
        let thread = try thread(10)
        for width: CGFloat in [900, 300, 0] {
            let host = host(thread, width: width)
            ActionChip.bodyCount = 0
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(ActionChip.bodyCount, 3 * 10, "\(ActionChip.bodyCount) chips built at width \(width)")
        }
    }

    /// The width it works out for a row is the width the row lays out at,
    /// for every count, so it shows the same chips a ViewThatFits would.
    func testTheRowWidthItWorksOutIsTheRowsWidth() throws {
        // 11, so "+N" goes from two digits to one along the way.
        let thread = try thread(11)
        let app = AppModel()
        func measure(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.environment(app)).fittingSize.width
        }
        var widths = ActionChipsFit.Widths()
        for action in thread.actions {
            widths.chips[action.id] = measure(ActionChip(action: action, running: false, run: {}))
        }
        XCTAssertEqual(ActionChipsFit.moreCounts(11), [9, 11])
        XCTAssertEqual(ActionChipsFit.moreCounts(3), [3])
        for count in ActionChipsFit.moreCounts(thread.actions.count) {
            widths.more[ActionChipsFit.digits(count)] = measure(ActionChipsMoreTab(threadId: thread.id, more: [], count: count))
        }
        for shown in 0...thread.actions.count {
            let row = ActionChipsRow(thread: thread, shown: Array(thread.actions.prefix(shown)), more: Array(thread.actions.dropFirst(shown)), waiting: [])
            let real = measure(row)
            let worked = try XCTUnwrap(ActionChipsFit.width(shown: shown, thread: thread, waiting: nil, widths: widths))
            XCTAssertEqual(worked, real, accuracy: 1.5, "\(shown) shown")
        }
        // The most that fit, and none when nothing does.
        let room = try XCTUnwrap(ActionChipsFit.width(shown: 3, thread: thread, waiting: nil, widths: widths)) + 1
        XCTAssertEqual(ActionChipsFit.shown(thread: thread, waiting: nil, widths: widths, room: room), 3)
        XCTAssertEqual(ActionChipsFit.shown(thread: thread, waiting: nil, widths: widths, room: 0), 0)
        XCTAssertEqual(ActionChipsFit.shown(thread: thread, waiting: nil, widths: widths, room: 10_000), 11)
        // Not until every chip has been measured.
        widths.chips["p:a2"] = nil
        XCTAssertNil(ActionChipsFit.shown(thread: thread, waiting: nil, widths: widths, room: 10_000))
    }
}
