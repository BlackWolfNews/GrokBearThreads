import AppKit
import ThreadbareCore

@MainActor
protocol RowCellDelegate: AnyObject {
    func toggleExpanded(rowId: String)
    func toggleChangedFile(turnId: String, path: String)
    /// "Show 30 more lines" under an opened diff: `key` is the diff's
    /// `DiffPreview.allKey`.
    func showAllLines(_ key: String)
    func respond(approvalId: String, decision: ApprovalDecision, answers: [String: String]?, message: String?)
    func questionDraft(_ approvalId: String) -> [Int: Set<String>]
    func setQuestionDraft(_ approvalId: String, _ draft: [Int: Set<String>])
}

/// Base for transcript cells: flipped, so layout reads top-down.
class RowCellView: NSTableCellView {
    weak var delegate: RowCellDelegate?
    var rowId = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hover.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        rowId = row.id
    }

    /// Called when the table takes the row off screen: let go of images and
    /// drawn text so parked cells cost little. `configure` or
    /// `updateSlices(force:)` restores them.
    func releaseContent() {}

    /// Moves tall text views' drawn slices to what's on screen.
    func updateSlices(force: Bool = false) {}

    // MARK: Hover

    /// A faint rounded fill behind `hoverRect` while the pointer is over it,
    /// for rows that open on a click. Cells that use it add `hover` first,
    /// so it sits behind their content.
    let hover = FillView()
    var hoverRect = NSRect.zero {
        didSet { updateHover() }
    }
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateHover() }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateHover() }
    override func mouseExited(with event: NSEvent) { pointer = nil; updateHover() }

    override func prepareForReuse() {
        super.prepareForReuse()
        pointer = nil
        updateHover()
    }

    #if DEBUG
    /// The automation hook's `hover`: draws the row as if the pointer were
    /// over the part a click opens. Returns false for a row with none.
    func debugHover(_ on: Bool) -> Bool {
        guard !on || hoverRect != .zero else { return false }
        pointer = on ? NSPoint(x: hoverRect.midX, y: hoverRect.midY) : nil
        updateHover()
        return true
    }
    #endif

    private func updateHover() {
        let on = hoverRect != .zero && pointer.map { hoverRect.contains($0) } == true
        if hover.isHidden == on { hover.isHidden = !on }
        if on, hover.frame != hoverRect {
            hover.frame = hoverRect
            hover.set(fill: Theme.hoverFill, stroke: nil, radius: 6)
        }
    }
}

/// A rounded box drawn in `draw(_:)`, so its dynamic colours follow light
/// and dark mode by themselves (layer colours have to be re-resolved).
final class FillView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 8 { didSet { needsDisplay = true } }
    /// A bar down the left edge, following the rounded corners (cards that
    /// need Mike).
    var accent: NSColor? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func set(fill: NSColor?, stroke: NSColor?, radius: CGFloat, accent: NSColor? = nil) {
        if self.fill != fill { self.fill = fill }
        if self.stroke != stroke { self.stroke = stroke }
        if self.radius != radius { self.radius = radius }
        if self.accent != accent { self.accent = accent }
    }

    override func draw(_ dirtyRect: NSRect) {
        if radius == 0 {
            // A plain fill (a hairline rule): no inset, or a 0.5 pt rule
            // would have no height left to fill.
            fill?.setFill()
            bounds.fill()
            return
        }
        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let corner = min(radius, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        if let accent {
            // The card's own left edge in the accent colour, drawn over the
            // border and clipped to the corners: a capsule floating inside
            // the card read as a quote rule in a box, with the grey border
            // still running down the edge beside it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).addClip()
            accent.setFill()
            NSRect(x: 0, y: 0, width: RowMetrics.accentBar, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Symbol images, made once: a new NSImage or tint makes an image view
/// rasterize its symbol again, which was the biggest main-thread cost of a
/// fast scroll (about 14%).
@MainActor
enum Symbols {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        cache[key] = image
        return image
    }

    static func set(_ view: NSImageView, _ name: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, tint: NSColor) {
        let image = self.image(name, size: size, weight: weight)
        if view.image !== image { view.image = image }
        if view.contentTintColor != tint { view.contentTintColor = tint }
    }

    static func makeView() -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        return view
    }
}

/// A one-line, truncating label.
@MainActor
func makeLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    return label
}

// MARK: - Text rows: user, assistant, plan, note, error, footer

final class TextRowCell: RowCellView {
    let textView = TranscriptTextView()
    let box = FillView()
    let images = ImageGridView()
    private var shownBlocks: [String] = []
    private var shownStarts: [Int] = []
    private var shownRowId = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(box)
        addSubview(textView)
        addSubview(images)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        let previousRowId = shownRowId
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let top = RowMetrics.rowTop
        box.isHidden = true
        images.isHidden = true
        textView.isHidden = render.text == nil

        switch row.content {
        case .user(let message) where message.isFromRunner:
            textView.place(NSRect(x: x, y: RowMetrics.runnerTop, width: width, height: render.textSize.height))

        case .user(let message):
            var y = RowMetrics.userTop
            if !message.images.isEmpty {
                // Attachments sit above the bubble, right-aligned, with no box.
                let area = floor(width * RowMetrics.bubbleShare)
                images.isHidden = false
                images.frame = NSRect(x: x + width - area, y: y, width: area, height: render.imageAreaHeight)
                images.show(paths: message.images.map(\.path), frames: render.imageFrames)
                y += render.imageAreaHeight + RowMetrics.imageGap
            }
            if render.text != nil {
                let maxBubble = floor(width * RowMetrics.bubbleShare)
                let bubbleWidth = min(maxBubble, render.textSize.width + RowMetrics.bubblePadH * 2)
                let bubble = NSRect(x: x + width - bubbleWidth, y: y, width: bubbleWidth, height: render.textSize.height + RowMetrics.bubblePadV * 2)
                box.isHidden = false
                box.frame = bubble
                box.set(fill: Theme.bubbleBackground, stroke: nil, radius: RowMetrics.bubbleRadius)
                textView.place(bubble.insetBy(dx: RowMetrics.bubblePadH, dy: RowMetrics.bubblePadV))
            }

        case .assistant:
            textView.place(NSRect(x: x, y: top, width: width, height: render.textSize.height))

        case .plan:
            box.isHidden = false
            box.set(fill: Theme.cardBackground, stroke: Theme.cardBorder, radius: 10)
            box.frame = NSRect(x: x, y: top + 2, width: width, height: render.textSize.height + RowMetrics.cardPad * 2 - 4)
            textView.place(box.frame.insetBy(dx: RowMetrics.cardPad, dy: RowMetrics.cardPad - 2))

        case .error:
            box.isHidden = false
            box.set(fill: Theme.errorBackground, stroke: nil, radius: 10)
            box.frame = NSRect(x: x, y: top, width: width, height: render.textSize.height + RowMetrics.boxPad * 2)
            textView.place(box.frame.insetBy(dx: RowMetrics.boxPad, dy: RowMetrics.boxPad))

        case .footer:
            textView.place(NSRect(x: x, y: 5, width: width, height: 17))

        default:
            textView.place(NSRect(x: x, y: top, width: width, height: render.textSize.height))
        }

        guard let text = render.text else { return }
        let textWidth = textView.fullFrame.width
        // A streaming assistant row only replaces the blocks that changed,
        // so TextKit lays out just the tail.
        if case .assistant = row.content, previousRowId == row.id, !shownBlocks.isEmpty,
           textView.textContainer?.size.width == textWidth {
            var common = 0
            while common < min(shownBlocks.count, render.blocks.count) - 1, shownBlocks[common] == render.blocks[common] {
                common += 1
            }
            let start = render.blockStarts.indices.contains(common) ? render.blockStarts[common] : 0
            let oldStart = shownStarts.indices.contains(common) ? shownStarts[common] : 0
            if start == oldStart {
                let tail = text.attributedSubstring(from: NSRange(location: start, length: text.length - start))
                textView.replaceTail(from: start, with: tail)
            } else {
                textView.show(text, width: textWidth)
            }
        } else {
            textView.show(text, width: textWidth)
        }
        shownBlocks = render.blocks
        shownStarts = render.blockStarts
        shownRowId = row.id
    }

    override func releaseContent() {
        // The text itself stays: laying it out again on every scroll back in
        // costs more frame time than the memory it frees. Its drawing goes.
        images.clear()
        textView.park()
    }

    override func updateSlices(force: Bool = false) {
        textView.updateSlice(force: force)
    }
}

// MARK: - Work rows: thinking, tools, diffs (and notes inside a group)

/// Every work line has the same shape, T3 and Codex style: an icon (or a
/// spinner) in a slot at the column edge, the text from
/// `RowMetrics.titleIndent`, and the chevron right after the words rather
/// than at the far end of the column.
enum WorkLine {
    /// The label's frame for text of `textWidth`, stopping short of
    /// `trailing` (room for the chevron and a failed badge).
    static func labelFrame(x: CGFloat, width: CGFloat, textWidth: CGFloat, trailing: CGFloat, rowHeight: CGFloat) -> NSRect {
        let left = x + RowMetrics.titleIndent - RowMetrics.labelInset
        let fit = ceil(textWidth) + RowMetrics.labelInset * 2
        let height = Theme.workLabelHeight
        return NSRect(x: left, y: (rowHeight - height) / 2, width: max(0, min(fit, x + width - left - trailing)), height: height)
    }

    static func iconFrame(x: CGFloat, rowHeight: CGFloat) -> NSRect {
        NSRect(x: x, y: (rowHeight - 16) / 2, width: 16, height: 16)
    }

    static func spinnerFrame(x: CGFloat, rowHeight: CGFloat) -> NSRect {
        NSRect(x: x + 1, y: (rowHeight - 14) / 2, width: 14, height: 14)
    }

    static func chevronFrame(after label: NSRect, rowHeight: CGFloat) -> NSRect {
        NSRect(x: label.maxX + 1, y: (rowHeight - 14) / 2 + 0.5, width: 14, height: 14)
    }

    /// What a click opens, and where the hover fill goes: the line from its
    /// icon to its chevron.
    static func hitRect(x: CGFloat, right: CGFloat, rowHeight: CGFloat) -> NSRect {
        NSRect(x: x - 6, y: 2, width: right - x + 12, height: rowHeight - 4)
    }
}

final class HeaderRowCell: RowCellView {
    let chevron = Symbols.makeView()
    let icon = Symbols.makeView()
    let title = makeLabel()
    let box = FillView()
    let body = TranscriptTextView()
    private var headerRect = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [hover, box, body, chevron, icon, title].forEach(addSubview)
        body.onAction = { [weak self] key in self?.delegate?.showAllLines(key) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let header = RowMetrics.workHeight
        if title.attributedStringValue != render.text { title.attributedStringValue = render.text ?? NSAttributedString() }

        var symbol = "brain"
        var tint = Theme.faintIcon
        var canExpand = true
        var tooltip: String?
        switch row.content {
        case .reasoning:
            symbol = "brain"
        case .tool(let tool):
            // A failed tool is marked once, by a red icon in the icon's
            // place; its title and output keep their usual colours.
            symbol = tool.failed ? "xmark.circle.fill" : ToolPresentation.symbol(for: tool.toolKind, name: tool.name)
            if tool.failed { tint = Theme.failed }
            // The title names just the file; the whole path is here.
            tooltip = ToolPresentation.fileTitle(tool)?.path
        case .approval(let item):
            switch item.resolution?.decision {
            case .deny?:
                symbol = "xmark.circle"
                tint = Theme.failed
            case .expired?: symbol = "clock"
            default: symbol = "checkmark.circle"
            }
            // Its tool's own row opens to the same thing.
            canExpand = item.opens
            tooltip = ToolPresentation.shortTitle(item.request.title, limit: 400)
        case .note:
            symbol = "info.circle"
            canExpand = false
        default:
            break
        }
        if title.toolTip != tooltip { title.toolTip = tooltip }
        Symbols.set(icon, symbol, size: 12, tint: tint)
        icon.frame = WorkLine.iconFrame(x: x, rowHeight: header)
        title.frame = WorkLine.labelFrame(x: x, width: width, textWidth: render.textSize.width, trailing: canExpand ? 16 : 0, rowHeight: header)
        var right = title.frame.maxX
        chevron.isHidden = !canExpand
        if canExpand {
            Symbols.set(chevron, expanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold, tint: Theme.faintIcon)
            chevron.frame = WorkLine.chevronFrame(after: title.frame, rowHeight: header)
            right = chevron.frame.maxX
        }
        headerRect = canExpand ? WorkLine.hitRect(x: x, right: right, rowHeight: header) : .zero
        hoverRect = headerRect
        window?.invalidateCursorRects(for: self)

        guard let detail = render.detail else {
            box.isHidden = true
            body.isHidden = true
            return
        }
        box.isHidden = false
        body.isHidden = false
        // Opened content sits under the title, past the icon slot.
        let left = x + RowMetrics.titleIndent
        let inner = width - RowMetrics.titleIndent
        switch row.content {
        case .reasoning:
            box.isHidden = true
            body.place(NSRect(x: left, y: header, width: inner, height: render.detailSize.height))
        default:
            if row.kind == .diff {
                box.set(fill: Theme.cardBackground, stroke: Theme.cardBorder, radius: 10)
                box.frame = NSRect(x: left, y: header + 2, width: inner, height: render.detailSize.height + RowMetrics.diffPadV * 2)
                body.place(NSRect(x: left + 0.5, y: box.frame.minY + RowMetrics.diffPadV, width: inner - 1, height: render.detailSize.height))
            } else {
                box.set(fill: Theme.codeBackground, stroke: Theme.cardBorder, radius: 8)
                box.frame = NSRect(x: left, y: header + 2, width: inner, height: render.detailSize.height + RowMetrics.boxPad * 2)
                body.place(box.frame.insetBy(dx: RowMetrics.boxPad, dy: RowMetrics.boxPad))
            }
        }
        body.show(detail, width: body.fullFrame.width)
    }

    override func releaseContent() {
        body.park()
    }

    override func updateSlices(force: Bool = false) {
        body.updateSlice(force: force)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if headerRect.contains(point) {
            delegate?.toggleExpanded(rowId: rowId)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if headerRect != .zero { addCursorRect(headerRect, cursor: .pointingHand) }
    }
}

// MARK: - Group summary line

/// "Read 3 files, ran 4 commands ›": a run of work folded into one line.
/// Clicking it opens the run under it. A live group says what it's doing
/// after a dot but keeps its icon: the working line under it is the turn's
/// one spinner (two stacked "busy" lines read as a stray child row).
final class GroupRowCell: RowCellView {
    let icon = Symbols.makeView()
    let label = makeLabel()
    let chevron = Symbols.makeView()
    private var hitRect = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [hover, icon, label, chevron].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .group(let group) = row.content else { return }
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let height = RowMetrics.workHeight
        if label.attributedStringValue != render.text { label.attributedStringValue = render.text ?? NSAttributedString() }
        // T3's mark for a run of tool calls; no single tool uses it.
        Symbols.set(icon, "hammer", size: 12, tint: Theme.faintIcon)
        icon.frame = WorkLine.iconFrame(x: x, rowHeight: height)
        label.frame = WorkLine.labelFrame(x: x, width: width, textWidth: render.textSize.width, trailing: 16, rowHeight: height)
        Symbols.set(chevron, group.isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold, tint: Theme.faintIcon)
        chevron.frame = WorkLine.chevronFrame(after: label.frame, rowHeight: height)
        hitRect = WorkLine.hitRect(x: x, right: chevron.frame.maxX, rowHeight: height)
        hoverRect = hitRect
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitRect.contains(point) {
            delegate?.toggleExpanded(rowId: rowId)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(hitRect, cursor: .pointingHand)
    }
}

// MARK: - Working line

/// "Working for 12s" with a spinner at the end of a running turn: the
/// turn's one status line. Counts by itself once a second while it's in a
/// window, so the row never re-renders as time passes.
final class WorkingRowCell: RowCellView {
    let spinner = SpinnerView()
    let label = makeLabel()
    private var startedAt: Date?
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The same tier as the label beside it: the system spinner's
        // palest spokes were about 1.6:1 on white.
        spinner.color = Theme.quietText
        // Body-sized secondary text, not the faintest grey in the window:
        // this line is what Mike watches while a turn runs.
        label.font = Theme.workFont
        label.textColor = Theme.quietText
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .working(let status) = row.content else { return }
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let height = RowMetrics.workingHeight
        spinner.frame = WorkLine.spinnerFrame(x: x, rowHeight: height)
        label.frame = WorkLine.labelFrame(x: x, width: width, textWidth: width, trailing: 0, rowHeight: height)
        startedAt = status.startedAt
        tick()
        startIfVisible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { startIfVisible() }
    }

    override func releaseContent() { stop() }

    private func startIfVisible() {
        guard window != nil else { return }
        spinner.start()
        guard timer == nil, startedAt != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        spinner.stop()
    }

    private func tick() {
        let text: String
        if let startedAt {
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            text = "Working for " + RelativeTime.duration(milliseconds: max(1000, elapsed * 1000))
        } else {
            text = "Working"
        }
        if label.stringValue != text { label.stringValue = text }
    }
}

// MARK: - Changed files card

/// "Edited 3 files": each file with its folder and line counts. Clicking a
/// file opens its diff under it.
final class ChangesRowCell: RowCellView {
    let card = FillView()
    let title = makeLabel()
    let total = makeLabel()
    let rule = FillView()
    private var fileRows: [(chevron: NSImageView, name: NSTextField, stats: NSTextField)] = []
    private var diffViews: [TranscriptTextView] = []
    private var hitRects: [(rect: NSRect, path: String)] = []
    private var turnId = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The hover fill sits on the card, behind the file names.
        [card, hover, title, total, rule].forEach(addSubview)
        total.alignment = .right
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .changes(let changes) = row.content else { return }
        turnId = changes.turnId
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        let top: CGFloat = 8
        card.set(fill: Theme.cardBackground, stroke: Theme.cardBorder, radius: 10)
        card.frame = NSRect(x: x, y: top, width: width, height: render.height - top - 6)
        let header = RowMetrics.changesHeader
        title.attributedStringValue = render.text ?? NSAttributedString()
        title.frame = NSRect(x: x + pad, y: top + (header - 18) / 2, width: width / 2, height: 18)
        // Line counts sit against the right edge, sized to fit (a label
        // wider than its text would truncate or drift left), on the same
        // baseline as the text beside them: centred on their own, the
        // smaller figures rode about 2 pt high.
        let totalWidth = ceil(render.detail?.size().width ?? 0) + 4
        total.attributedStringValue = render.detail ?? NSAttributedString()
        total.frame = NSRect(x: x + width - pad - totalWidth, y: title.frame.minY + Theme.changesTitleFont.ascender - Theme.statsFont.ascender,
                             width: totalWidth, height: 17)
        rule.set(fill: Theme.hairline, stroke: nil, radius: 0)
        rule.frame = NSRect(x: x + 0.5, y: top + header - 0.5, width: width - 1, height: 0.5)

        hitRects = []
        hoverRect = .zero
        var y = top + header
        var diffIndex = 0
        for (index, part) in render.parts.enumerated() {
            if fileRows.count <= index {
                let entry = (chevron: Symbols.makeView(), name: makeLabel(), stats: makeLabel())
                entry.stats.alignment = .right
                [entry.chevron, entry.name, entry.stats].forEach(addSubview)
                fileRows.append(entry)
            }
            let entry = fileRows[index]
            let file = changes.files.indices.contains(index) ? changes.files[index] : nil
            let rowHeight = RowMetrics.changesFile
            for view in [entry.chevron, entry.name, entry.stats] as [NSView] { view.isHidden = false }
            Symbols.set(entry.chevron, file?.isExpanded == true ? "chevron.down" : "chevron.right", size: 9, weight: .semibold, tint: Theme.faintIcon)
            entry.chevron.frame = NSRect(x: x + pad - 2, y: y + (rowHeight - 14) / 2, width: 14, height: 14)
            let statsWidth = ceil(part.trailing?.size().width ?? 0) + 4
            entry.name.attributedStringValue = part.leading
            let nameHeight = Theme.workLabelHeight
            entry.name.frame = NSRect(x: x + pad + 18, y: y + (rowHeight - nameHeight) / 2, width: width - pad * 2 - 18 - statsWidth - 12, height: nameHeight)
            entry.stats.attributedStringValue = part.trailing ?? NSAttributedString()
            entry.stats.frame = NSRect(x: x + width - pad - statsWidth, y: entry.name.frame.minY + Theme.workFont.ascender - Theme.statsFont.ascender,
                                       width: statsWidth, height: 17)
            if let path = file?.path { hitRects.append((NSRect(x: x, y: y, width: width, height: rowHeight), path)) }
            y += rowHeight
            if let body = part.body {
                if diffViews.count <= diffIndex {
                    let view = TranscriptTextView()
                    view.onAction = { [weak self] key in self?.delegate?.showAllLines(key) }
                    addSubview(view)
                    diffViews.append(view)
                }
                let view = diffViews[diffIndex]
                view.isHidden = false
                view.place(NSRect(x: x + 0.5, y: y, width: width - 1, height: part.bodyHeight - 8))
                view.show(body, width: width - 1)
                y += part.bodyHeight
                diffIndex += 1
            }
        }
        for entry in fileRows.dropFirst(render.parts.count) {
            for view in [entry.chevron, entry.name, entry.stats] as [NSView] { view.isHidden = true }
        }
        for view in diffViews.dropFirst(diffIndex) {
            view.isHidden = true
            view.clear()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func releaseContent() {
        diffViews.forEach { $0.park() }
    }

    override func updateSlices(force: Bool = false) {
        diffViews.forEach { $0.updateSlice(force: force) }
    }

    // The file under the pointer gets the hover fill every other line that
    // opens on a click has. Only its line, not its open diff.
    override func mouseEntered(with event: NSEvent) {
        hoverRect = fileRect(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        hoverRect = fileRect(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    private func fileRect(at point: NSPoint) -> NSRect {
        hitRects.first { $0.rect.contains(point) }.map { $0.rect.insetBy(dx: 4, dy: 1) } ?? .zero
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitRects.first(where: { $0.rect.contains(point) }) {
            delegate?.toggleChangedFile(turnId: turnId, path: hit.path)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        for hit in hitRects { addCursorRect(hit.rect, cursor: .pointingHand) }
    }
}

// MARK: - Images

final class ImagesRowCell: RowCellView {
    let grid = ImageGridView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(grid)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .images(_, let images) = row.content else { return }
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        grid.frame = NSRect(x: x, y: RowMetrics.rowTop + 2, width: width, height: render.imageAreaHeight)
        grid.show(paths: images.map(\.path), frames: render.imageFrames)
    }

    override func releaseContent() {
        grid.clear()
    }
}

// MARK: - Buttons

/// A capsule button drawn the same in light and dark: the prominent one
/// filled with the accent colour, the others a hairline outline.
final class PillButton: NSButton {
    var prominent = false { didSet { needsDisplay = true } }
    /// A key drawn faintly after the title ("Allow  ⏎").
    var shortcut: String? { didSet { needsDisplay = true } }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    convenience init(pill title: String, prominent: Bool = false, shortcut: String? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.prominent = prominent
        self.shortcut = shortcut
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
    }

    static let font = NSFont.systemFont(ofSize: TypeScale.label, weight: .medium)
    static let shortcutFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var fittingWidth: CGFloat {
        ceil(label(color: .labelColor).size().width) + 30
    }

    private func label(color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        if let shortcut {
            let faint = prominent && isEnabled ? NSColor.white.withAlphaComponent(0.7) : NSColor.tertiaryLabelColor
            text.append(NSAttributedString(string: "  " + shortcut, attributes: [.font: Self.shortcutFont, .foregroundColor: faint]))
        }
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let pressed = isHighlighted
        if prominent, !isEnabled {
            // Nothing to send yet: no accent fill pretending it would work.
            Theme.inlineCodeBackground.setFill()
            path.fill()
        } else if prominent {
            NSColor.controlAccentColor.blended(withFraction: pressed ? 0.2 : 0, of: .black)?.setFill()
            path.fill()
        } else {
            (pressed ? Theme.inlineCodeBackground : Theme.cardBackground).setFill()
            path.fill()
            Theme.cardBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = !isEnabled ? .tertiaryLabelColor : prominent ? .white : .labelColor
        let text = label(color: color)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Approval card

final class ApprovalRowCell: RowCellView {
    let card = FillView()
    let titleView = TranscriptTextView()
    let payloadBox = FillView()
    let payloadView = TranscriptTextView()
    /// Return in an empty composer allows it too (ComposerView).
    let allow = PillButton(pill: "Allow", prominent: true, shortcut: "⏎")
    let always = PillButton(pill: "Always allow")
    let deny = PillButton(pill: "Deny")
    private var approvalId = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, action) in [(allow, #selector(allowClicked)), (always, #selector(alwaysClicked)), (deny, #selector(denyClicked))] {
            button.target = self
            button.action = action
        }
        [card, titleView, payloadBox, payloadView, allow, always, deny].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .approval(let item) = row.content else { return }
        approvalId = item.request.approvalId
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        // Only a waiting approval gets this card; once answered it's a work
        // line (HeaderRowCell).
        let pending = item.resolution == nil
        let top = RowMetrics.rowTop + 2
        card.frame = NSRect(x: x, y: top, width: width, height: render.height - top - RowMetrics.rowBottom - 2)
        card.set(fill: Theme.cardBackground, stroke: Theme.cardBorder, radius: RowMetrics.cardRadius, accent: .controlAccentColor)
        let left = x + pad + RowMetrics.accentBar
        let inner = width - pad * 2 - RowMetrics.accentBar
        var y = card.frame.minY + pad
        titleView.place(NSRect(x: left, y: y, width: inner, height: render.textSize.height))
        titleView.show(render.text ?? NSAttributedString(), width: inner)
        let path = ApprovalText.filePath(item.request).map { ToolPresentation.shortTitle($0, limit: 400) }
        if titleView.toolTip != path { titleView.toolTip = path }
        y += render.textSize.height + 10
        payloadBox.set(fill: Theme.codeBackground, stroke: nil, radius: 8)
        payloadBox.frame = NSRect(x: left, y: y, width: inner, height: render.detailSize.height + RowMetrics.boxPad * 2)
        payloadView.place(payloadBox.frame.insetBy(dx: RowMetrics.boxPad, dy: RowMetrics.boxPad))
        payloadView.show(render.detail ?? NSAttributedString(), width: inner - RowMetrics.boxPad * 2)
        y = payloadBox.frame.maxY + 12

        // Allow first and filled; Deny last, on the right of the row.
        let options = Set(item.request.options)
        var buttonX = left
        for (button, option) in [(allow, ApprovalOption.allow), (always, .allowAlways), (deny, .deny)] {
            button.isHidden = !pending || !options.contains(option)
            guard !button.isHidden else { continue }
            button.frame = NSRect(x: buttonX, y: y, width: max(76, button.fittingWidth), height: RowMetrics.buttonHeight)
            buttonX = button.frame.maxX + 8
        }
    }

    override func releaseContent() {
        titleView.park()
        payloadView.park()
    }

    override func updateSlices(force: Bool = false) {
        titleView.updateSlice(force: force)
        payloadView.updateSlice(force: force)
    }

    @objc private func allowClicked() { delegate?.respond(approvalId: approvalId, decision: .allow, answers: nil, message: nil) }
    @objc private func alwaysClicked() { delegate?.respond(approvalId: approvalId, decision: .allowAlways, answers: nil, message: nil) }
    @objc private func denyClicked() { delegate?.respond(approvalId: approvalId, decision: .deny, answers: nil, message: nil) }
}

// MARK: - Question card

/// One question's text, options and option notes. Each question gets its own
/// view so AppKit's automatic radio grouping (same superview, same action)
/// can't link the options of different questions.
private final class QuestionGroupView: NSView {
    let label = TranscriptTextView()
    var buttons: [NSButton] = []
    var notes: [NSTextField] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class QuestionRowCell: RowCellView, NSTextFieldDelegate {
    let card = FillView()
    /// "Something else": a plain field in a rounded box like the approval
    /// card's payload. The system's rounded bezel was the only bright,
    /// hard-edged box in the transcript.
    let otherBox = FillView()
    let other = NSTextField()
    let send = PillButton(pill: "Send answer", prominent: true)
    let answerIcon = Symbols.makeView()
    let answer = makeLabel()
    private var request: QuestionRequest?
    private var groups: [QuestionGroupView] = []
    private var buttons: [(question: Int, label: String, button: NSButton)] = []
    /// What the question views were last laid out for. The same question at
    /// the same width (scrolling it back into view, a draft change) only
    /// updates button states; rebuilding every view and measuring the text
    /// on each configure made a 580 pt card cost a 100 ms frame in a fling.
    private var builtFor: String?
    private var optionsBottom: CGFloat = 0
    private var editing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        other.font = .systemFont(ofSize: TypeScale.work)
        // The composer's placeholder tier, set outright: a borderless field
        // otherwise picks its own grey.
        other.placeholderAttributedString = NSAttributedString(string: "Something else", attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.work), .foregroundColor: ComposerTextView.placeholderColor,
        ])
        other.isBezeled = false
        other.isBordered = false
        other.drawsBackground = false
        other.focusRingType = .none
        other.delegate = self
        send.target = self
        send.action = #selector(sendClicked)
        [card, otherBox, other, send, answerIcon, answer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .question(let item) = row.content else { return }
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        let left = x + pad + RowMetrics.accentBar
        let inner = width - pad * 2 - RowMetrics.accentBar
        let pending = item.resolution == nil
        let top = RowMetrics.rowTop + 2
        card.frame = NSRect(x: x, y: top, width: width, height: render.height - top - RowMetrics.rowBottom - 2)
        // Answered, it's history: an outline with no fill or accent, so a
        // card still waiting on Mike stands out from it.
        card.set(fill: pending ? Theme.cardBackground : nil, stroke: Theme.cardBorder, radius: RowMetrics.cardRadius,
                 accent: pending ? .controlAccentColor : nil)

        let key = "\(row.id)|\(row.version)|\(Int(tableWidth))"
        if builtFor != key {
            if request?.approvalId != item.request.approvalId { other.stringValue = "" }
            request = item.request
            layoutQuestions(item.request, render: render, x: left, top: card.frame.minY + pad, width: inner, answered: !pending)
            builtFor = key
        }
        let draft = delegate?.questionDraft(item.request.approvalId) ?? [:]
        for entry in buttons {
            entry.button.state = draft[entry.question]?.contains(entry.label) == true ? .on : .off
        }

        var y = optionsBottom
        for view in [otherBox, other, send] as [NSView] { view.isHidden = !pending }
        answerIcon.isHidden = pending
        answer.isHidden = pending
        if let resolution = item.resolution {
            let (symbol, tint): (String, NSColor) = switch resolution.decision {
            case .answered: ("checkmark.circle.fill", .controlAccentColor)
            case .expired: ("clock", Theme.faintIcon)
            default: ("xmark.circle", Theme.faintIcon)
            }
            Symbols.set(answerIcon, symbol, size: 13, tint: tint)
            answerIcon.frame = NSRect(x: left, y: y + (RowMetrics.answerHeight - 16) / 2, width: 16, height: 16)
            if answer.attributedStringValue != render.text { answer.attributedStringValue = render.text ?? NSAttributedString() }
            // Text from the same edge as a work line's after its icon, less
            // the label's own inset so the glyphs line up.
            let textX = left + RowMetrics.titleIndent - RowMetrics.labelInset
            let height = Theme.workLabelHeight
            answer.frame = NSRect(x: textX, y: y + (RowMetrics.answerHeight - height) / 2, width: left + inner - textX + RowMetrics.labelInset, height: height)
            answer.toolTip = resolution.message
        } else {
            otherBox.frame = NSRect(x: left, y: y, width: inner, height: RowMetrics.otherFieldHeight)
            updateOtherBox()
            let fieldHeight = ceil(other.intrinsicContentSize.height)
            other.frame = NSRect(x: left + RowMetrics.boxPad - RowMetrics.labelInset, y: y + (RowMetrics.otherFieldHeight - fieldHeight) / 2,
                                 width: inner - RowMetrics.boxPad * 2 + RowMetrics.labelInset * 2, height: fieldHeight)
            y += RowMetrics.otherFieldHeight + 2 + 12
            send.frame = NSRect(x: left, y: y, width: max(110, send.fittingWidth), height: RowMetrics.buttonHeight)
            updateSend()
        }
    }

    /// The box's outline takes the accent colour while Mike types in it,
    /// standing in for the focus ring the plain field doesn't draw.
    private func updateOtherBox() {
        otherBox.set(fill: Theme.codeBackground, stroke: editing ? NSColor.controlAccentColor.withAlphaComponent(0.5) : Theme.cardBorder, radius: 8)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editing = true
        updateOtherBox()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        updateOtherBox()
    }

    /// "Send answer" only looks (and is) clickable once there's an answer.
    private func updateSend() {
        guard let request else { return }
        let draft = delegate?.questionDraft(request.approvalId) ?? [:]
        let typed = other.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = !Self.answers(for: request, chosen: draft, typed: typed).isEmpty
        if send.isEnabled != ready { send.isEnabled = ready }
    }

    /// Places each question's views, reusing the ones already made. An
    /// answered card shows just its questions; the answer goes under them.
    private func layoutQuestions(_ request: QuestionRequest, render: RowRender, x: CGFloat, top: CGFloat, width: CGFloat, answered: Bool) {
        buttons = []
        var y = top
        for (index, question) in request.questions.enumerated() {
            if groups.count <= index {
                let group = QuestionGroupView(frame: .zero)
                addSubview(group)
                groups.append(group)
            }
            let group = groups[index]
            group.isHidden = false
            let text = RowRenderer.questionText(question.question, answered: answered)
            // Heights come from the render (measured off the main thread).
            let height = render.lineHeights.indices.contains(index)
                ? render.lineHeights[index] : TextMeasurer.current.measure(text, width: width).height
            group.label.frame = NSRect(x: 0, y: 0, width: width, height: height)
            group.label.show(text, width: width)
            if answered {
                group.buttons.forEach { $0.isHidden = true }
                group.notes.forEach { $0.isHidden = true }
                group.frame = NSRect(x: x, y: y, width: width, height: height)
                y += height + RowMetrics.answeredGap
                continue
            }
            var inner = height + 8
            var noteIndex = 0
            for (optionIndex, option) in question.options.enumerated() {
                if group.buttons.count <= optionIndex {
                    let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(optionClicked(_:)))
                    button.font = .systemFont(ofSize: TypeScale.work)
                    group.addSubview(button)
                    group.buttons.append(button)
                }
                let button = group.buttons[optionIndex]
                button.isHidden = false
                button.setButtonType(question.multiSelect ? .switch : .radio)
                if button.title != option.label { button.title = option.label }
                button.frame = NSRect(x: 0, y: inner, width: width, height: RowMetrics.optionHeight)
                buttons.append((index, option.label, button))
                inner += RowMetrics.optionHeight
                if let description = option.description, !description.isEmpty {
                    if group.notes.count <= noteIndex {
                        let note = makeLabel()
                        note.font = Theme.labelFont
                        note.textColor = .secondaryLabelColor
                        group.addSubview(note)
                        group.notes.append(note)
                    }
                    let note = group.notes[noteIndex]
                    note.isHidden = false
                    if note.stringValue != description { note.stringValue = description }
                    note.frame = NSRect(x: 20, y: inner - 2, width: width - 20, height: RowMetrics.optionDescription)
                    inner += RowMetrics.optionDescription
                    noteIndex += 1
                }
            }
            for button in group.buttons.dropFirst(question.options.count) { button.isHidden = true }
            for note in group.notes.dropFirst(noteIndex) { note.isHidden = true }
            group.frame = NSRect(x: x, y: y, width: width, height: inner)
            y += inner + 12
        }
        for group in groups.dropFirst(request.questions.count) { group.isHidden = true }
        optionsBottom = y
    }

    @objc private func optionClicked(_ sender: NSButton) {
        guard let request, let entry = buttons.first(where: { $0.button === sender }) else { return }
        var draft = delegate?.questionDraft(request.approvalId) ?? [:]
        var chosen = draft[entry.question] ?? []
        if request.questions[entry.question].multiSelect {
            if sender.state == .on { chosen.insert(entry.label) } else { chosen.remove(entry.label) }
        } else {
            chosen = [entry.label]
            for other in buttons where other.question == entry.question && other.button !== sender { other.button.state = .off }
            // Choosing an option for the last question replaces typed text.
            if entry.question == request.questions.count - 1 { other.stringValue = "" }
        }
        draft[entry.question] = chosen
        delegate?.setQuestionDraft(request.approvalId, draft)
        updateSend()
    }

    /// Typing "Something else" for a single-choice last question clears its
    /// chosen option, so the answer is one or the other, never both.
    func controlTextDidChange(_ notification: Notification) {
        defer { updateSend() }
        guard let request, let last = request.questions.indices.last, !request.questions[last].multiSelect,
              !other.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var draft = delegate?.questionDraft(request.approvalId) ?? [:]
        guard draft[last]?.isEmpty == false else { return }
        draft[last] = []
        delegate?.setQuestionDraft(request.approvalId, draft)
        for entry in buttons where entry.question == last { entry.button.state = .off }
    }

    @objc private func sendClicked() {
        guard let request else { return }
        let draft = delegate?.questionDraft(request.approvalId) ?? [:]
        let typed = other.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let answers = Self.answers(for: request, chosen: draft, typed: typed)
        guard !answers.isEmpty else { return }
        // The answers also go as the message, which the runner keeps in the
        // transcript (only `answers` goes to the CLI), so the card can show
        // what was chosen after the drafts are gone.
        delegate?.respond(approvalId: request.approvalId, decision: .answered, answers: answers,
                          message: ApprovalText.answerSummary(request, answers: answers))
    }

    /// The `answers` map for `approvals.respond`. "Something else" is the
    /// answer to the last question: it replaces a single choice and is added
    /// to multiple ones. It never fills in other questions.
    static func answers(for request: QuestionRequest, chosen: [Int: Set<String>], typed: String) -> [String: String] {
        var answers: [String: String] = [:]
        let last = request.questions.count - 1
        for (index, question) in request.questions.enumerated() {
            var parts = question.options.map(\.label).filter { chosen[index]?.contains($0) == true }
            if !typed.isEmpty, index == last {
                if question.multiSelect { parts.append(typed) } else { parts = [typed] }
            }
            if !parts.isEmpty { answers[question.question] = parts.joined(separator: ", ") }
        }
        return answers
    }
}

extension NSColor {
    /// Resolves a dynamic colour for a view's current appearance, for layers.
    func resolvedCGColor(for view: NSView) -> CGColor {
        var color = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = self.cgColor
        }
        return color
    }
}
