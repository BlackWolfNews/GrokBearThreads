import Foundation
import Testing
@testable import BearDock

// Small builders so each tree reads like the picture of it.
private func g(_ id: String, _ panels: [PanelID], _ selected: PanelID? = nil) -> DockNode {
    .group(DockGroup(id: id, panels: panels, selected: selected))
}
private func h(_ id: String, _ children: [DockNode], _ fractions: [Double]? = nil) -> DockNode {
    .split(DockSplit(id: id, axis: .horizontal, children: children, fractions: fractions))
}
private func v(_ id: String, _ children: [DockNode], _ fractions: [Double]? = nil) -> DockNode {
    .split(DockSplit(id: id, axis: .vertical, children: children, fractions: fractions))
}
/// "n1", "n2", ... so new ids are predictable.
private func ids() -> () -> String {
    var n = 0
    return { n += 1; return "n\(n)" }
}

/// Threadbear's option 2: threads | transcript | highlights over convex.
private func threeColumns() -> DockLayout {
    DockLayout(root: h("root", [
        g("left", ["threads"]),
        g("mid", ["transcript"]),
        v("right", [g("hl", ["highlights"]), g("cx", ["convex"])]),
    ], [0.25, 0.5, 0.25]))
}

@Test func edgeAlongTheSameAxisJoinsAsASiblingSharingTheTargetsSpace() {
    var layout = threeColumns()
    layout.move("convex", .edge(group: "mid", .right), newID: ids())
    #expect(layout.root == h("root", [
        g("left", ["threads"]),
        g("mid", ["transcript"]),
        g("n1", ["convex"]),
        g("hl", ["highlights"]),
    ], [0.25, 0.25, 0.25, 0.25]))
}

@Test func edgeAcrossTheAxisWrapsTheTargetInANewSplit() {
    var layout = threeColumns()
    layout.move("threads", .edge(group: "mid", .bottom), newID: ids())
    // threads' column went, so its quarter is shared between the rest.
    #expect(layout.root == h("root", [
        v("n2", [g("mid", ["transcript"]), g("n1", ["threads"])]),
        v("right", [g("hl", ["highlights"]), g("cx", ["convex"])]),
    ], [0.5 / 0.75, 0.25 / 0.75]))
}

@Test func nestingGoesAsDeepAsYouLike() {
    var layout = threeColumns()
    let next = ids()
    layout.move("threads", .edge(group: "cx", .left), newID: next)   // n1, in split n2
    layout.move("highlights", .edge(group: "n1", .top), newID: next) // n3, in split n4
    layout.move("convex", .edge(group: "n1", .right), newID: next)   // n5, in split n6
    // Three levels: a row, a column in it, a row in that.
    guard case .split(let root) = layout.root else { Issue.record("expected a split"); return }
    #expect(root.children == [
        g("mid", ["transcript"]),
        v("n4", [g("n3", ["highlights"]), h("n6", [g("n1", ["threads"]), g("n5", ["convex"])])]),
    ])
    // threads' quarter went to the right, then convex's sixth back to both.
    #expect(abs(root.fractions[0] - 0.8) < 1e-9)
}

@Test func movingTheOnlyPanelOutCollapsesItsGroupAndSplit() {
    var layout = threeColumns()
    layout.move("highlights", .tab(group: "mid"))
    // The right column is down to convex alone, so it's just that group now.
    #expect(layout.root == h("root", [
        g("left", ["threads"]),
        g("mid", ["transcript", "highlights"], "highlights"),
        g("cx", ["convex"]),
    ], [0.25, 0.5, 0.25]))
}

@Test func sameAxisSplitsFlatten() {
    let node = h("a", [g("x", ["X"]), h("b", [g("y", ["Y"]), g("z", ["Z"])])], [0.5, 0.5])
    #expect(DockLayout.normalised(node) == h("a", [g("x", ["X"]), g("y", ["Y"]), g("z", ["Z"])], [0.5, 0.25, 0.25]))
}

@Test func takingASelectedTabShowsItsNeighbour() {
    var layout = DockLayout(root: h("root", [g("a", ["A", "B", "C"], "B"), g("d", ["D"])]))
    layout.move("B", .tab(group: "d"))
    #expect(layout.group(id: "a")?.selected == "C")
    #expect(layout.group(id: "d") == DockGroup(id: "d", panels: ["D", "B"], selected: "B"))
    layout.move("C", .tab(group: "d"))
    #expect(layout.group(id: "a")?.selected == "A")
}

@Test func splittingAGroupByOneOfItsOwnTabs() {
    var layout = DockLayout(root: g("a", ["A", "B"]))
    layout.move("B", .edge(group: "a", .right), newID: ids())
    #expect(layout.root == h("n2", [g("a", ["A"]), g("n1", ["B"])]))
}

@Test func swapTradesPlaces() {
    var layout = threeColumns()
    layout.move("threads", .swap(group: "cx"))
    #expect(layout.group(id: "left")?.panels == ["convex"])
    #expect(layout.group(id: "cx") == DockGroup(id: "cx", panels: ["threads"]))
}

@Test func windowEdgesSpanTheWholeSide() {
    var layout = threeColumns()
    let next = ids()
    layout.move("convex", .window(.right), newID: next)
    #expect(layout.root == h("root", [
        g("left", ["threads"]),
        g("mid", ["transcript"]),
        g("hl", ["highlights"]),
        g("n1", ["convex"]),
    ], [0.1875, 0.375, 0.1875, 0.25]))

    layout.move("threads", .window(.bottom), newID: next)
    guard case .split(let root) = layout.root else { Issue.record("expected a split"); return }
    #expect(root.axis == .vertical)
    #expect(root.fractions == [0.75, 0.25])
    #expect(root.children.last == g("n2", ["threads"]))
}

@Test func dropsThatGoNowhereAreRefused() {
    let layout = threeColumns()
    #expect(!layout.canDrop("threads", .edge(group: "left", .right)))
    #expect(!layout.canDrop("threads", .tab(group: "left")))
    #expect(!layout.canDrop("threads", .swap(group: "left")))
    #expect(!layout.canDrop("nope", .tab(group: "left")))
    #expect(!layout.canDrop("threads", .tab(group: "nope")))
    #expect(!DockLayout(root: g("a", ["A"])).canDrop("A", .window(.left)))
    #expect(layout.canDrop("threads", .edge(group: "mid", .left)))
    var unchanged = layout
    unchanged.move("threads", .tab(group: "left"))
    #expect(unchanged == layout)
}

@Test func closeAndAddBack() {
    var layout = threeColumns()
    layout.close("convex")
    #expect(!layout.contains("convex"))
    layout.add("convex", .tab(group: "hl"))
    #expect(layout.group(id: "hl")?.panels == ["highlights", "convex"])
    var single = DockLayout(root: g("a", ["A"]))
    single.close("A")
    #expect(single.root == g("a", ["A"]))
}

@Test func dividerFractionsStayNormalised() {
    var layout = threeColumns()
    layout.setFractions(split: "root", [1, 2, 1])
    guard case .split(let root) = layout.root else { Issue.record("expected a split"); return }
    #expect(root.fractions == [0.25, 0.5, 0.25])
}

@Test func roundTripsThroughJSON() throws {
    let layout = threeColumns()
    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(DockLayout.self, from: data) == layout)
}
