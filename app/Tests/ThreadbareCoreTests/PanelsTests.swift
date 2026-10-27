import XCTest
@testable import ThreadbareCore

final class PanelsTests: XCTestCase {
    func testSummaryDecodesPanelsAndSkipsBrokenOnes() throws {
        let json = """
        {"id":"th1","panels":[
          {"id":"convex.dashboard","title":"Convex","kind":"url","url":"https://dashboard.convex.dev/d/quick-fox-77","patch":"convex","note":"quick-fox-77 (dev)"},
          {"id":"xcode.simulator","title":"Simulator","kind":"image","patch":"xcode"},
          {"id":"future.thing","title":"Later","kind":"hologram","patch":"future","extra":1},
          {"title":"no id"}
        ]}
        """
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(thread.panels.map(\.id), ["convex.dashboard", "xcode.simulator", "future.thing"])
        XCTAssertEqual(thread.panels[0].kind, .url)
        XCTAssertEqual(thread.panels[0].pageURL?.host, "dashboard.convex.dev")
        XCTAssertEqual(thread.panels[1].kind, .image)
        XCTAssertNil(thread.panels[1].url)
        // An unknown kind is shown as a page, the one thing every panel can be.
        XCTAssertEqual(thread.panels[2].kind, .url)
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.panels, thread.panels)
        let none = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"x"}"#.utf8))
        XCTAssertEqual(none.panels, [])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("panels"))
    }

    func testActivePanelIsTheRememberedOneIfStillThereElseTheFirst() {
        let convex = Panel(id: "convex.dashboard", title: "Convex", url: "https://dashboard.convex.dev", patch: "convex")
        let sim = Panel(id: "xcode.simulator", title: "Simulator", kind: .image, patch: "xcode")
        XCTAssertEqual(PanelChoice.active(in: [convex, sim], remembered: nil), convex)
        XCTAssertEqual(PanelChoice.active(in: [convex, sim], remembered: "xcode.simulator"), sim)
        XCTAssertEqual(PanelChoice.active(in: [convex], remembered: "xcode.simulator"), convex)
        XCTAssertNil(PanelChoice.active(in: [], remembered: "xcode.simulator"))
    }

    func testPaneWidthStaysInsideTheColumn() {
        XCTAssertEqual(PanelChoice.clampedWidth(420, paneColumnWidth: 1000), 420)
        XCTAssertEqual(PanelChoice.clampedWidth(100, paneColumnWidth: 1000), PanelChoice.minWidth)
        XCTAssertEqual(PanelChoice.clampedWidth(900, paneColumnWidth: 1000), 640)
        // A tiny column: the pane keeps its minimum rather than vanishing.
        XCTAssertEqual(PanelChoice.clampedWidth(420, paneColumnWidth: 500), PanelChoice.minWidth)
    }
}
