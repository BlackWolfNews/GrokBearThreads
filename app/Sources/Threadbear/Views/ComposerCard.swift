import AppKit
import SwiftUI
import ThreadbearCore

/// The open card (Needs you, or Done with its follow-ups) at the top of
/// the composer, over a line, so the card and the box it's answered in
/// read as one thing. Mike picked that from mockups on 30 Oct; it was
/// first built as a card at the end of the transcript, which he didn't
/// recognise as what he'd chosen. The card is drawn as it was in the
/// transcript: a bare TextRowCell, its clicks going to the transcript's
/// controller, which looks after the thread on show.
///
/// A card of asks can be collapsed to its heading with the chevron at its
/// top right, to read the reply behind it (Mike, 30 Oct).
struct ComposerCard: NSViewRepresentable {
    let row: TranscriptRow
    var collapsed = false
    let controller: TranscriptController

    func makeNSView(context: Context) -> ComposerCardHost {
        ComposerCardHost(controller: controller)
    }

    func updateNSView(_ view: ComposerCardHost, context: Context) {
        view.attach(controller)
        view.show(row, collapsed: collapsed)
    }

    /// SwiftUI asks this many times a layout pass, once for each stack
    /// the card sits in and for each probe, and the window asks again for
    /// its smallest size. Building the card every time (each page of it,
    /// with its symbol images) froze the app for 5 to 19 seconds (5 Nov,
    /// THREADBEAR-X), so the host answers from the card it built last.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerCardHost, context: Context) -> CGSize? {
        let width = ComposerCardHost.measuringWidth(proposal.width)
        let full = nsView.rendered(row, width: width, collapsed: collapsed).height
        return CGSize(width: width, height: min(full, nsView.maxHeight))
    }
}

final class ComposerCardHost: NSView {
    private let cell = TextRowCell()
    /// A card taller than `maxHeight` scrolls inside the box: three asks
    /// with their buttons pushed the agent's reply off the top.
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private weak var controller: TranscriptController?
    private var row: TranscriptRow?
    private var collapsed = false
    /// A real button rather than a `.tbAction` run like the pager's, so it
    /// has a tooltip, and stays put while a tall card scrolls under it.
    private let toggle = NSHostingView(rootView: CardCollapseButton(collapsed: false, action: {}))
    private var shown: (row: TranscriptRow, collapsed: Bool, width: CGFloat, zoom: Int)?
    /// The Something else box to put the cursor in once the card has made
    /// room for it (picking it and the card growing happen a beat apart).
    private var pendingFocus: Int?
    /// The ask a paged card is showing, and the card it's for: a new card
    /// opens on its first unanswered ask.
    private(set) var page = 0
    private var pageSeq: Int?
    /// The card built for each width it's been asked about, for this row,
    /// page, collapse and text size; any of those changing starts afresh.
    private var built: (row: TranscriptRow, page: Int, collapsed: Bool, zoom: Int, renders: [CGFloat: RowRender])?

    override var isFlipped: Bool { true }

    init(controller: TranscriptController) {
        self.controller = controller
        super.init(frame: .zero)
        cell.bare = true
        cell.delegate = controller
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.addSubview(cell)
        addSubview(scroll)
        // It's framed by hand in layout, so it mustn't add constraints.
        toggle.sizingOptions = []
        addSubview(toggle)
        controller.composerCard = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ controller: TranscriptController) {
        if controller.composerCard !== self { controller.composerCard = self }
        guard controller !== self.controller else { return }
        self.controller = controller
        cell.delegate = controller
    }

    /// Over this, a card of several asks shows one at a time, with
    /// ‹ 1 of 3 › by its heading (Mike, 30 Oct: three asks took most of
    /// the window). Two short asks still fit, and stay as one list.
    static var pagedOver: CGFloat { zoomed(240) }

    static func isPaged(_ card: AsksCard, height: CGFloat) -> Bool {
        card.isOpen && card.asks.count > 1 && height > pagedOver
    }

    /// The card at `width`. A paged one is drawn on `page` but as tall as
    /// its tallest page, so the composer doesn't jump up and down and the
    /// arrows stay put under the pointer while he pages through.
    static func render(_ row: TranscriptRow, width: CGFloat, page: Int = 0, collapsed: Bool = false) -> RowRender {
        #if DEBUG
        renderCount += 1
        #endif
        guard case .asks(let card) = row.content else { return RowRender(height: 0) }
        let measure = { (text: NSAttributedString) in TextMeasurer.current.measure(text, width: width) }
        if collapsed {
            let heading = RowRenderer.asksText(card, width: width, collapsed: true)
            let size = measure(heading)
            // Never shorter than the chevron beside it.
            return RowRender(height: max(size.height, toggleSize), text: heading, textSize: size)
        }
        let all = RowRenderer.asksText(card, width: width)
        let full = measure(all)
        guard isPaged(card, height: full.height) else { return RowRender(height: full.height, text: all, textSize: full) }
        let shown = min(max(page, 0), card.asks.count - 1)
        var text = all
        var size = full
        var tallest: CGFloat = 0
        for index in card.asks.indices {
            let pageText = RowRenderer.asksText(card, width: width, page: index)
            let pageSize = measure(pageText)
            tallest = max(tallest, pageSize.height)
            if index == shown { (text, size) = (pageText, pageSize) }
        }
        return RowRender(height: tallest, text: text, textSize: size)
    }

    /// The width to build the card at for a proposed one: the reading
    /// column when SwiftUI leaves it open or offers no end, and never so
    /// narrow that TextKit lays the card out a letter a line (the window's
    /// smallest-size pass offers next to nothing).
    static func measuringWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return Theme.maxContentWidth }
        return max(proposed, zoomed(160))
    }

    /// `render`, from what was built last when nothing's changed.
    func rendered(_ row: TranscriptRow, width: CGFloat, collapsed: Bool) -> RowRender {
        let zoom = TypeScale.percent
        if let built, built.row == row, built.page == page, built.collapsed == collapsed, built.zoom == zoom {
            if let render = built.renders[width] { return render }
        } else {
            built = (row, page, collapsed, zoom, [:])
        }
        let render = Self.render(row, width: width, page: page, collapsed: collapsed)
        // A few widths while the window's resized; not one for every step.
        if built!.renders.count >= 8 { built!.renders.removeAll() }
        built!.renders[width] = render
        return render
    }

    func show(_ row: TranscriptRow, collapsed: Bool = false) {
        guard row != self.row || collapsed != self.collapsed else { return }
        self.row = row
        self.collapsed = collapsed
        if case .asks(let card) = row.content, card.seq != pageSeq {
            pageSeq = card.seq
            page = card.asks.indices.first { card.picks[$0] == nil } ?? 0
        }
        needsLayout = true
    }

    /// ‹ and › on a paged card (`page:<n>`).
    func showPage(_ index: Int) {
        guard case .asks(let card)? = row?.content, card.asks.indices.contains(index), index != page else { return }
        page = index
        shown = nil
        needsLayout = true
    }

    /// After an answer's picked on a paged card, on to the next ask still
    /// waiting for one, a beat later so the tick shows first. Stays put
    /// once they're all answered, so he can look over the last one.
    func pagePast(_ index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.page == index, case .asks(let card)? = self.row?.content, self.bounds.width > 0 else { return }
            let full = TextMeasurer.current.measure(RowRenderer.asksText(card, width: self.bounds.width), width: self.bounds.width)
            guard Self.isPaged(card, height: full.height) else { return }
            let count = card.asks.count
            if let next = (1..<count).map({ (index + $0) % count }).first(where: { card.picks[$0] == nil }) {
                self.showPage(next)
            }
        }
    }

    /// Under half the window, so the reply it answers stays in sight.
    var maxHeight: CGFloat {
        max(zoomed(200), (window?.contentLayoutRect.height ?? 800) * 0.45)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        guard let row, bounds.width > 0 else { return }
        let zoom = TypeScale.percent
        if let shown, shown.row == row, shown.collapsed == collapsed, shown.width == bounds.width, shown.zoom == zoom { return }
        shown = (row, collapsed, bounds.width, zoom)
        placeToggle(row)
        let render = rendered(row, width: bounds.width, collapsed: collapsed)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: render.height)
        cell.frame = document.bounds
        cell.configure(row: row, render: render, tableWidth: bounds.width, expanded: false)
        if let ask = pendingFocus, cell.focusAnswerBox(ask) { pendingFocus = nil }
    }

    #if DEBUG
    /// How many times a card's been built, for tests.
    nonisolated(unsafe) static var renderCount = 0
    #endif

    static var toggleSize: CGFloat { zoomed(22) }

    /// The chevron, at the right of the heading line and centred on it,
    /// which is a button tall on a paged card. Only asks collapse: a done
    /// card has Archive there, and is short already.
    private func placeToggle(_ row: TranscriptRow) {
        guard case .asks(let card) = row.content, !card.isDone else {
            toggle.isHidden = true
            return
        }
        let width = bounds.width
        let full = TextMeasurer.current.measure(RowRenderer.asksText(card, width: width), width: width)
        let line = !collapsed && Self.isPaged(card, height: full.height) ? TypeScale.scaled(38) : TypeScale.workLine
        let size = Self.toggleSize
        toggle.frame = NSRect(x: width - size, y: max(0, (line - size) / 2), width: size, height: size)
        toggle.isHidden = false
        toggle.rootView = CardCollapseButton(collapsed: collapsed) { [weak self] in
            guard let self, case .asks(let card)? = self.row?.content else { return }
            self.controller?.askAction(card, action: "collapse")
        }
    }

    func focusAnswerBox(_ ask: Int) {
        if !cell.focusAnswerBox(ask) { pendingFocus = ask }
    }

    #if DEBUG
    func debugHover(_ on: Bool) -> Bool { cell.debugHover(on) }
    #endif
}

/// Points where the card will go: down to tuck it into the composer, up
/// to bring it back.
private struct CardCollapseButton: View {
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: zoomed(11), weight: .semibold))
        }
        .buttonStyle(RowIconButtonStyle())
        .accessibilityLabel(collapsed ? "Expand" : "Collapse")
        .tip(collapsed ? "Expand" : "Collapse")
        // Its own hosting view, outside RootView's (FirstClick.swift).
        .allowsWindowActivationEvents()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
