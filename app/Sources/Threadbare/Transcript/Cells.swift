import AppKit
import ThreadbareCore

@MainActor
protocol RowCellDelegate: AnyObject {
    func toggleExpanded(rowId: String)
    func respond(approvalId: String, decision: ApprovalDecision, answers: [String: String]?, message: String?)
    func questionDraft(_ approvalId: String) -> [Int: Set<String>]
    func setQuestionDraft(_ approvalId: String, _ draft: [Int: Set<String>])
}

/// Base for transcript cells: flipped, so layout reads top-down.
class RowCellView: NSTableCellView {
    weak var delegate: RowCellDelegate?
    var rowId = ""

    override var isFlipped: Bool { true }

    func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        rowId = row.id
    }

    /// Called when the table takes the row off screen: let go of images and
    /// drawn text so parked cells cost little. `configure` or
    /// `updateSlices(force:)` restores them.
    func releaseContent() {}

    /// Moves tall text views' drawn slices to what's on screen.
    func updateSlices(force: Bool = false) {}

    static func makeBox() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        return view
    }
}

// MARK: - Text rows: user, assistant, plan, note, error, footer

final class TextRowCell: RowCellView {
    let textView = TranscriptTextView()
    let box = RowCellView.makeBox()
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
        let (x, width) = RowMetrics.column(tableWidth: tableWidth)
        let top = RowMetrics.rowTop
        box.isHidden = true
        images.isHidden = true
        textView.isHidden = render.text == nil
        box.layer?.borderWidth = 0

        switch row.content {
        case .user(let message):
            let maxBubble = floor(width * 0.84)
            let bubbleWidth = min(maxBubble, render.textSize.width + RowMetrics.bubblePadH * 2)
            var y = top + 6
            if render.text != nil {
                let bubble = NSRect(x: x + width - bubbleWidth, y: y, width: bubbleWidth, height: render.textSize.height + RowMetrics.bubblePadV * 2)
                box.isHidden = false
                box.frame = bubble
                box.layer?.cornerRadius = 12
                box.layer?.backgroundColor = Theme.bubbleBackground.resolvedCGColor(for: self)
                textView.place(bubble.insetBy(dx: RowMetrics.bubblePadH, dy: RowMetrics.bubblePadV))
                y = bubble.maxY + RowMetrics.imageGap
            }
            if !message.images.isEmpty {
                images.isHidden = false
                images.frame = NSRect(x: x, y: y, width: width, height: render.imageAreaHeight)
                images.show(paths: message.images.map(\.path), frames: render.imageFrames)
            }

        case .assistant:
            textView.place(NSRect(x: x, y: top, width: width, height: render.textSize.height + 2))

        case .plan:
            box.isHidden = false
            box.layer?.cornerRadius = 8
            box.layer?.backgroundColor = NSColor.clear.cgColor
            box.layer?.borderWidth = 1
            box.layer?.borderColor = Theme.cardBorder.resolvedCGColor(for: self)
            box.frame = NSRect(x: x, y: top, width: width, height: render.textSize.height + RowMetrics.cardPad * 2)
            textView.place(box.frame.insetBy(dx: RowMetrics.cardPad, dy: RowMetrics.cardPad))

        case .error:
            box.isHidden = false
            box.layer?.cornerRadius = 8
            box.layer?.backgroundColor = Theme.errorBackground.resolvedCGColor(for: self)
            box.frame = NSRect(x: x, y: top, width: width, height: render.textSize.height + RowMetrics.boxPad * 2)
            textView.place(box.frame.insetBy(dx: RowMetrics.boxPad, dy: RowMetrics.boxPad))

        case .footer:
            textView.place(NSRect(x: x, y: 6, width: width, height: 16))

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colours don't follow appearance changes on their own.
        needsLayout = true
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

// MARK: - Header rows: reasoning, tools, diffs

final class HeaderRowCell: RowCellView {
    let chevron = NSImageView()
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let status = NSImageView()
    let box = RowCellView.makeBox()
    let body = TranscriptTextView()
    private var headerRect = NSRect.zero
    private var spinning = false
    private static var symbols: [String: NSImage] = [:]

    private static func set(_ view: NSImageView, symbol: String, tint: NSColor) {
        let image: NSImage?
        if let cached = symbols[symbol] {
            image = cached
        } else {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            symbols[symbol] = image
        }
        if view.image !== image { view.image = image }
        if view.contentTintColor != tint { view.contentTintColor = tint }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [chevron, icon, status] {
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = .tertiaryLabelColor
        }
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.truncatesLastVisibleLine = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        [box, body, chevron, icon, title, spinner, status].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        let (x, width) = RowMetrics.column(tableWidth: tableWidth)
        let header = RowMetrics.headerHeight
        headerRect = NSRect(x: x, y: 0, width: width, height: header)
        title.attributedStringValue = render.text ?? NSAttributedString()

        var symbol = "brain"
        var running = false
        var failed = false
        var canExpand = true
        switch row.content {
        case .reasoning(let item):
            symbol = "brain"
            running = item.isStreaming
        case .tool(let tool):
            symbol = ToolPresentation.symbol(for: tool.toolKind, name: tool.name)
            running = !tool.isFinished
            failed = tool.failed
            if row.kind == .diff, let diff = tool.effectiveDiff {
                let lines = diff.hunks.reduce(0) { $0 + $1.lines.count }
                canExpand = lines > RowMetrics.collapsedDiffLines
            }
        default:
            break
        }
        // Images and tints are only set when they change: a new NSImage or
        // tint makes the image view rasterize its symbol again, which was
        // the biggest main-thread cost of a fast scroll (about 14%).
        Self.set(chevron, symbol: expanded ? "chevron.down" : "chevron.right", tint: .tertiaryLabelColor)
        chevron.isHidden = !canExpand
        chevron.frame = NSRect(x: x - 16, y: (header - 12) / 2, width: 12, height: 12)
        Self.set(icon, symbol: symbol, tint: failed ? .systemRed : .secondaryLabelColor)
        icon.frame = NSRect(x: x, y: (header - 15) / 2, width: 15, height: 15)
        let accessory: CGFloat = 20
        title.frame = NSRect(x: x + 22, y: (header - 17) / 2, width: width - 22 - accessory, height: 17)
        if running {
            spinner.frame = NSRect(x: x + width - 16, y: (header - 16) / 2, width: 16, height: 16)
            if !spinning {
                spinner.startAnimation(nil)
                spinning = true
            }
        } else if spinning {
            spinner.stopAnimation(nil)
            spinning = false
        }
        status.isHidden = !failed
        if failed {
            Self.set(status, symbol: "xmark.circle.fill", tint: .systemRed)
            status.frame = NSRect(x: x + width - 15, y: (header - 14) / 2, width: 14, height: 14)
        }

        guard let detail = render.detail else {
            box.isHidden = true
            body.isHidden = true
            return
        }
        box.isHidden = false
        body.isHidden = false
        box.layer?.borderWidth = 0
        switch row.content {
        case .reasoning:
            box.isHidden = true
            body.place(NSRect(x: x + RowMetrics.bodyIndent, y: header + 2, width: width - RowMetrics.bodyIndent, height: render.detailSize.height))
        default:
            if row.kind == .diff {
                box.layer?.backgroundColor = NSColor.clear.cgColor
                box.layer?.borderWidth = 1
                box.layer?.borderColor = Theme.cardBorder.resolvedCGColor(for: self)
                box.layer?.cornerRadius = 6
                box.frame = NSRect(x: x, y: header, width: width, height: render.detailSize.height + RowMetrics.diffPad * 2)
                body.place(box.frame.insetBy(dx: RowMetrics.diffPad, dy: RowMetrics.diffPad))
            } else {
                box.layer?.backgroundColor = Theme.codeBackground.resolvedCGColor(for: self)
                box.layer?.cornerRadius = 6
                box.frame = NSRect(x: x + RowMetrics.bodyIndent, y: header, width: width - RowMetrics.bodyIndent, height: render.detailSize.height + RowMetrics.boxPad * 2)
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
        if headerRect.insetBy(dx: -20, dy: 0).contains(point) {
            delegate?.toggleExpanded(rowId: rowId)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(headerRect, cursor: .pointingHand)
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
        let (x, width) = RowMetrics.column(tableWidth: tableWidth)
        grid.frame = NSRect(x: x + RowMetrics.bodyIndent, y: RowMetrics.rowTop, width: width - RowMetrics.bodyIndent, height: render.imageAreaHeight)
        grid.show(paths: images.map(\.path), frames: render.imageFrames)
    }

    override func releaseContent() {
        grid.clear()
    }
}

// MARK: - Approval card

final class ApprovalRowCell: RowCellView {
    let card = RowCellView.makeBox()
    let titleView = TranscriptTextView()
    let detailView = TranscriptTextView()
    let allow = NSButton(title: "Allow", target: nil, action: nil)
    let always = NSButton(title: "Always allow", target: nil, action: nil)
    let deny = NSButton(title: "Deny", target: nil, action: nil)
    let resolved = NSTextField(labelWithString: "")
    private var approvalId = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, action) in [(allow, #selector(allowClicked)), (always, #selector(alwaysClicked)), (deny, #selector(denyClicked))] {
            button.bezelStyle = .push
            button.controlSize = .regular
            button.target = self
            button.action = action
        }
        allow.keyEquivalent = ""
        resolved.font = Theme.smallFont
        resolved.textColor = .secondaryLabelColor
        [card, titleView, detailView, allow, always, deny, resolved].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .approval(let item) = row.content else { return }
        approvalId = item.request.approvalId
        let (x, width) = RowMetrics.column(tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        card.frame = NSRect(x: x, y: RowMetrics.rowTop, width: width, height: render.height - RowMetrics.rowTop - RowMetrics.rowBottom)
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        let pending = item.resolution == nil
        card.layer?.borderColor = (pending ? NSColor.controlAccentColor : Theme.cardBorder).resolvedCGColor(for: self)
        card.layer?.backgroundColor = Theme.bubbleBackground.resolvedCGColor(for: self)
        var y = card.frame.minY + pad
        titleView.frame = NSRect(x: x + pad, y: y, width: width - pad * 2, height: render.textSize.height)
        titleView.show(render.text ?? NSAttributedString(), width: width - pad * 2)
        y += render.textSize.height + 6
        detailView.frame = NSRect(x: x + pad, y: y, width: width - pad * 2, height: render.detailSize.height)
        detailView.show(render.detail ?? NSAttributedString(), width: width - pad * 2)
        y += render.detailSize.height + 10

        let options = Set(item.request.options)
        var buttonX = x + pad
        for (button, option) in [(allow, ApprovalOption.allow), (always, .allowAlways), (deny, .deny)] {
            button.isHidden = !pending || !options.contains(option)
            guard !button.isHidden else { continue }
            button.sizeToFit()
            button.frame = NSRect(x: buttonX, y: y, width: max(72, button.frame.width), height: RowMetrics.buttonHeight)
            buttonX = button.frame.maxX + 8
        }
        resolved.isHidden = pending
        if let resolution = item.resolution {
            resolved.stringValue = Self.label(resolution.decision)
            resolved.frame = NSRect(x: x + pad, y: y + 6, width: width - pad * 2, height: 16)
        }
    }

    static func label(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .allow: return "Allowed"
        case .allowAlways: return "Always allowed"
        case .deny: return "Denied"
        case .answered: return "Answered"
        case .expired: return "Expired when the runner restarted"
        }
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
    let card = RowCellView.makeBox()
    let other = NSTextField()
    let send = NSButton(title: "Send answer", target: nil, action: nil)
    let resolved = NSTextField(wrappingLabelWithString: "")
    private var request: QuestionRequest?
    private var groups: [QuestionGroupView] = []
    private var buttons: [(question: Int, label: String, button: NSButton)] = []
    /// What the question views were last laid out for. The same question at
    /// the same width (scrolling it back into view, a draft change) only
    /// updates button states; rebuilding every view and measuring the text
    /// on each configure made a 580 pt card cost a 100 ms frame in a fling.
    private var builtFor: String?
    private var optionsBottom: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        other.placeholderString = "Something else"
        other.font = Theme.bodyFont
        other.delegate = self
        send.bezelStyle = .push
        send.target = self
        send.action = #selector(sendClicked)
        resolved.font = Theme.smallFont
        resolved.textColor = .secondaryLabelColor
        [card, other, send, resolved].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .question(let item) = row.content else { return }
        let (x, width) = RowMetrics.column(tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        let inner = width - pad * 2
        let pending = item.resolution == nil
        card.frame = NSRect(x: x, y: RowMetrics.rowTop, width: width, height: render.height - RowMetrics.rowTop - RowMetrics.rowBottom)
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (pending ? NSColor.controlAccentColor : Theme.cardBorder).resolvedCGColor(for: self)
        card.layer?.backgroundColor = Theme.bubbleBackground.resolvedCGColor(for: self)

        let key = "\(row.id)|\(row.version)|\(Int(tableWidth))"
        if builtFor != key {
            if request?.approvalId != item.request.approvalId { other.stringValue = "" }
            request = item.request
            layoutQuestions(item.request, render: render, x: x + pad, top: card.frame.minY + pad, width: inner)
            builtFor = key
        }
        let draft = delegate?.questionDraft(item.request.approvalId) ?? [:]
        for entry in buttons {
            entry.button.state = draft[entry.question]?.contains(entry.label) == true ? .on : .off
            entry.button.isEnabled = pending
        }

        var y = optionsBottom
        other.isHidden = !pending
        send.isHidden = !pending
        resolved.isHidden = pending
        if pending {
            other.frame = NSRect(x: x + pad, y: y, width: inner, height: 24)
            y += 26 + 8
            send.sizeToFit()
            send.frame = NSRect(x: x + pad, y: y, width: max(110, send.frame.width), height: RowMetrics.buttonHeight)
        } else {
            let message = item.resolution?.message.flatMap { $0.isEmpty ? nil : $0 }
            resolved.stringValue = message.map { "Answered: \(RowRenderer.firstLine($0))" } ?? ApprovalRowCell.label(item.resolution?.decision ?? .answered)
            resolved.frame = NSRect(x: x + pad, y: y, width: inner, height: 16)
        }
    }

    /// Places each question's views, reusing the ones already made.
    private func layoutQuestions(_ request: QuestionRequest, render: RowRender, x: CGFloat, top: CGFloat, width: CGFloat) {
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
            let text = RowRenderer.questionText(question.question)
            // Heights come from the render (measured off the main thread).
            let height = render.lineHeights.indices.contains(index)
                ? render.lineHeights[index] : TextMeasurer.current.measure(text, width: width).height
            group.label.frame = NSRect(x: 0, y: 0, width: width, height: height)
            group.label.show(text, width: width)
            var inner = height + 6
            var noteIndex = 0
            for (optionIndex, option) in question.options.enumerated() {
                if group.buttons.count <= optionIndex {
                    let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(optionClicked(_:)))
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
                        let note = NSTextField(labelWithString: "")
                        note.font = Theme.smallFont
                        note.textColor = .secondaryLabelColor
                        note.lineBreakMode = .byTruncatingTail
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
            y += inner + 10
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
    }

    /// Typing "Something else" for a single-choice last question clears its
    /// chosen option, so the answer is one or the other, never both.
    func controlTextDidChange(_ notification: Notification) {
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
        delegate?.respond(approvalId: request.approvalId, decision: .answered, answers: answers, message: nil)
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
