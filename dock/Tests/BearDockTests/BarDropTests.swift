import Foundation
import Testing
@testable import BearDock

// Dragging a panel over another group's bar joins it as a tab, shown as a
// tab after the titles there (Mike, 28 Oct).

@MainActor
private func controller() -> DockController {
    let c = DockController(layout: DockLayout(root: .split(DockSplit(id: "root", axis: .horizontal, children: [
        .group(DockGroup(id: "mid", panels: ["transcript"])),
        .group(DockGroup(id: "right", panels: ["highlights", "worktrees"])),
    ]))))
    c.bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    c.frames = ["mid": CGRect(x: 0, y: 0, width: 600, height: 800), "right": CGRect(x: 600, y: 0, width: 400, height: 800)]
    c.bars = ["mid": CGRect(x: 0, y: 0, width: 600, height: 32), "right": CGRect(x: 600, y: 0, width: 400, height: 32)]
    c.barSpaceStarts = ["mid": 120, "right": 820]
    return c
}

@MainActor @Test func overAnotherGroupsBarItJoinsAsATab() {
    let target = controller().target(for: "worktrees", at: CGPoint(x: 300, y: 16))
    #expect(target?.drop == .tab(group: "mid"))
    #expect(target?.inBar == true)
    // The tab is drawn after the title, and the panel lands in the whole group.
    #expect(target?.preview.minX == 124)
    #expect(target?.land == CGRect(x: 0, y: 0, width: 600, height: 800))
}

@MainActor @Test func theWindowsTopEdgeStillDocksAlongTheVeryTop() {
    #expect(controller().target(for: "worktrees", at: CGPoint(x: 300, y: 2))?.drop == .window(.top))
}

@MainActor @Test func belowTheBarTheGroupsOwnTargetsAreBack() {
    let target = controller().target(for: "worktrees", at: CGPoint(x: 300, y: 60))
    #expect(target?.inBar == false)
}
