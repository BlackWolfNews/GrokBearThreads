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
struct ComposerCard: NSViewRepresentable {
    let row: TranscriptRow
    let controller: TranscriptController

    func makeNSView(context: Context) -> ComposerCardHost {
        ComposerCardHost(controller: controller)
    }

    func updateNSView(_ view: ComposerCardHost, context: Context) {
        view.attach(controller)
        view.show(row)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerCardHost, context: Context) -> CGSize? {
        let width = proposal.width ?? Theme.maxContentWidth
        let full = ComposerCardHost.render(row, width: width).height
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
    private var shown: (row: TranscriptRow, width: CGFloat, zoom: Int)?
    /// The Something else box to put the cursor in once the card has made
    /// room for it (picking it and the card growing happen a beat apart).
    private var pendingFocus: Int?

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
        controller.composerCard = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ controller: TranscriptController) {
        if controller.composerCard !== self { controller.composerCard = self }
        guard controller !== self.controller else { return }
        self.controller = controller
        cell.delegate = controller
    }

    static func render(_ row: TranscriptRow, width: CGFloat) -> RowRender {
        guard case .asks(let card) = row.content else { return RowRender(height: 0) }
        let text = RowRenderer.asksText(card, width: width)
        let size = TextMeasurer.current.measure(text, width: width)
        return RowRender(height: size.height, text: text, textSize: size)
    }

    func show(_ row: TranscriptRow) {
        guard row != self.row else { return }
        self.row = row
        needsLayout = true
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
        if let shown, shown.row == row, shown.width == bounds.width, shown.zoom == zoom { return }
        shown = (row, bounds.width, zoom)
        let render = Self.render(row, width: bounds.width)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: render.height)
        cell.frame = document.bounds
        cell.configure(row: row, render: render, tableWidth: bounds.width, expanded: false)
        if let ask = pendingFocus, cell.focusAnswerBox(ask) { pendingFocus = nil }
    }

    func focusAnswerBox(_ ask: Int) {
        if !cell.focusAnswerBox(ask) { pendingFocus = ask }
    }

    #if DEBUG
    func debugHover(_ on: Bool) -> Bool { cell.debugHover(on) }
    #endif
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
