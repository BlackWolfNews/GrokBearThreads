import AppKit
import Synchronization
import ThreadbareCore

/// Layout numbers shared by height measurement and the cell views, so the
/// two always agree.
enum RowMetrics {
    static let rowTop: CGFloat = 6
    static let rowBottom: CGFloat = 6
    /// Space above a user message, which starts a turn: the biggest gap in
    /// the transcript, so turns read apart.
    static let userTop: CGFloat = 26
    /// Space under the bubble before the turn's work. At 10 the message sat
    /// right on top of the reply, closer than the gaps inside a turn; T3
    /// and Codex leave a clear pause there.
    static let userBottom: CGFloat = 22
    /// One line of work: a group summary, a tool call, a thinking block.
    static let workHeight: CGFloat = 32
    static let workingHeight: CGFloat = 34
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 10
    static let bubbleRadius: CGFloat = 18
    /// The widest a user bubble gets, as a share of the column.
    static let bubbleShare: CGFloat = 0.8
    static let boxPad: CGFloat = 10
    static let diffPadV: CGFloat = 6
    /// Where a work line's text starts, after its icon. Every work line
    /// (group, tool, thinking, the working line) has its icon or spinner in
    /// the slot before it, so their text shares one edge.
    static let titleIndent: CGFloat = 22
    /// An NSTextField label draws its text this far in from its frame;
    /// work line labels start this much left so their glyphs line up.
    static let labelInset: CGFloat = 2
    /// How far an open group's items sit in from its summary line.
    static let groupIndent: CGFloat = 18
    static let cardPad: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let accentBar: CGFloat = 3
    static let buttonHeight: CGFloat = 28
    static let optionHeight: CGFloat = 24
    static let optionDescription: CGFloat = 17
    /// The question card's "Something else" field.
    static let otherFieldHeight: CGFloat = 30
    /// An answered question: the space under each question, and the line
    /// with the answer.
    static let answeredGap: CGFloat = 6
    static let answerHeight: CGFloat = 20
    static let userThumbHeight: CGFloat = 120
    static let gridMaxHeight: CGFloat = 240
    static let gridMaxWidth: CGFloat = 320
    static let imageGap: CGFloat = 8
    /// The most lines an opened diff shows in the flow once Mike asks for
    /// all of it (it opens at `DiffPreview.lines`).
    static let maxDiffLines = 1500
    static let footerHeight: CGFloat = 27
    /// A message the runner sent by itself after a restart: a centred note
    /// right under the restart's own note, with room before the work it
    /// starts.
    static let runnerTop: CGFloat = 4
    static let runnerBottom: CGFloat = 18
    static let changesHeader: CGFloat = 42
    static let changesFile: CGFloat = 34

    /// The reading column for a given table width: (x, width).
    static func column(tableWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = max(200, min(tableWidth - Theme.sideInset * 2, Theme.maxContentWidth))
        return (floor((tableWidth - width) / 2), floor(width))
    }

    /// The row's own column: an open group's items sit in from the edge.
    static func column(for row: TranscriptRow, tableWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let (x, width) = column(tableWidth: tableWidth)
        return row.inGroup ? (x + groupIndent, width - groupIndent) : (x, width)
    }
}

/// Everything a cell needs to draw one row at one width, plus its height.
/// Immutable once built, so it's shared across threads.
final class RowRender: @unchecked Sendable {
    let height: CGFloat
    let text: NSAttributedString?
    let textSize: NSSize
    let detail: NSAttributedString?
    let detailSize: NSSize
    /// Markdown blocks and where each starts in `text` (assistant rows), for
    /// in-place streaming updates.
    let blocks: [String]
    let blockStarts: [Int]
    /// Image frames relative to the image area's top-left.
    let imageFrames: [NSRect]
    let imageAreaHeight: CGFloat
    /// Measured heights of a question card's question texts.
    let lineHeights: [CGFloat]
    /// A changes card's files.
    let parts: [Part]

    /// One line of a card (a changed file) and what opens under it.
    struct Part {
        var leading: NSAttributedString
        var trailing: NSAttributedString?
        var body: NSAttributedString?
        var bodyHeight: CGFloat = 0
    }

    init(height: CGFloat, text: NSAttributedString? = nil, textSize: NSSize = .zero, detail: NSAttributedString? = nil, detailSize: NSSize = .zero,
         blocks: [String] = [], blockStarts: [Int] = [], imageFrames: [NSRect] = [], imageAreaHeight: CGFloat = 0, lineHeights: [CGFloat] = [], parts: [Part] = []) {
        self.height = height
        self.text = text
        self.textSize = textSize
        self.detail = detail
        self.detailSize = detailSize
        self.blocks = blocks
        self.blockStarts = blockStarts
        self.imageFrames = imageFrames
        self.imageAreaHeight = imageAreaHeight
        self.lineHeights = lineHeights
        self.parts = parts
    }
}

/// Caches renders by (row id, content version, expanded, in a group, width).
final class RenderCache: @unchecked Sendable {
    private let cache = NSCache<NSString, RowRender>()
    /// For rows that are still changing (streaming text, a running tool):
    /// the key of the one version kept. Each streaming flush is a new
    /// version, and keeping them all pushed every other thread's renders out
    /// of the cache within seconds of a long reply.
    private let liveKeys = Mutex<[String: NSString]>([:])

    init() {
        // The cost limit is the real bound; this just has to be above a
        // long thread's row count at two widths.
        cache.countLimit = 10_000
        // Rough bytes (see `cost`): enough for a few thousand typical rows
        // without letting a run of huge expanded outputs pile up.
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    /// A rough size: attributed strings cost far more than their UTF-16.
    static func cost(_ render: RowRender) -> Int {
        let parts = render.parts.reduce(0) { $0 + $1.leading.length + ($1.body?.length ?? 0) }
        let characters = (render.text?.length ?? 0) + (render.detail?.length ?? 0) + parts
        return 512 + characters * 12 + render.blocks.reduce(0) { $0 + $1.utf8.count }
    }

    /// Groups and changes cards carry their open state in their content
    /// (and so in their version); the flag is only for item rows.
    static func effectiveExpanded(_ row: TranscriptRow, _ expanded: Bool) -> Bool {
        switch row.content {
        case .group(let group): return group.isExpanded
        case .changes, .working: return false
        default: return expanded
        }
    }

    /// "Show all lines" only changes an opened diff row; for anything else
    /// it would just split the cache.
    static func effectiveShowAll(_ row: TranscriptRow, expanded: Bool, showAll: Bool) -> Bool {
        showAll && row.kind == .diff && effectiveExpanded(row, expanded)
    }

    /// 0 closed, 1 open, 2 open with every line of its diff.
    static func openLevel(_ row: TranscriptRow, expanded: Bool, showAll: Bool) -> Int {
        guard effectiveExpanded(row, expanded) else { return 0 }
        return effectiveShowAll(row, expanded: expanded, showAll: showAll) ? 2 : 1
    }

    /// Keyed by the reading column's width, which is all a render depends
    /// on: tables of different widths with the column at its widest share
    /// renders, so a sidebar drag or a scroller appearing costs nothing.
    static func key(_ row: TranscriptRow, expanded: Bool, showAll: Bool = false, width: CGFloat) -> NSString {
        let open = openLevel(row, expanded: expanded, showAll: showAll)
        return "\(row.id)|\(row.version)|\(open)|\(row.inGroup ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))" as NSString
    }

    func cached(_ row: TranscriptRow, expanded: Bool, showAll: Bool = false, width: CGFloat) -> RowRender? {
        cache.object(forKey: Self.key(row, expanded: expanded, showAll: showAll, width: width))
    }

    func render(_ row: TranscriptRow, expanded: Bool, showAll: Bool = false, width: CGFloat) -> RowRender {
        let key = Self.key(row, expanded: expanded, showAll: showAll, width: width)
        if let hit = cache.object(forKey: key) { return hit }
        let render = RowRenderer.render(row, expanded: Self.effectiveExpanded(row, expanded),
                                        showAll: Self.effectiveShowAll(row, expanded: expanded, showAll: showAll),
                                        tableWidth: width, measurer: .current)
        store(render, key: key, row: row, open: Self.openLevel(row, expanded: expanded, showAll: showAll), width: width)
        return render
    }

    private func store(_ render: RowRender, key: NSString, row: TranscriptRow, open: Int, width: CGFloat) {
        cache.setObject(render, forKey: key, cost: Self.cost(render))
        let slot = "\(row.id)|\(open)|\(row.inGroup ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))"
        let live = row.isLive
        let superseded: NSString? = liveKeys.withLock { keys in
            let old = keys[slot]
            keys[slot] = live ? key : nil
            return old == key ? nil : old
        }
        if let superseded { cache.removeObject(forKey: superseded) }
    }

    /// Renders rows across all cores. Used before showing a thread or
    /// paging in older rows, so the main thread only reads the cache.
    func prepare(_ rows: [TranscriptRow], expanded: Set<String>, width: CGFloat) {
        func showAll(_ row: TranscriptRow) -> Bool { row.kind == .diff && expanded.contains(DiffPreview.allKey(row.id)) }
        let missing = rows.filter { cached($0, expanded: expanded.contains($0.id), showAll: showAll($0), width: width) == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: missing.count) { index in
            let row = missing[index]
            _ = render(row, expanded: expanded.contains(row.id), showAll: showAll(row), width: width)
        }
    }

    func removeAll() { cache.removeAllObjects() }
}

extension TranscriptRow {
    /// Still changing: streaming text, a tool that hasn't finished, or a
    /// group that's still growing.
    var isLive: Bool {
        switch content {
        case .assistant(let item), .reasoning(let item): return item.isStreaming
        case .tool(let tool): return !tool.isFinished
        case .group(let group): return group.isLive
        default: return false
        }
    }
}

/// Measures the streaming assistant message incrementally. It keeps the
/// last text it measured in its own TextKit 1 stack and replaces only the
/// blocks from the first one that changed, so TextKit lays out just the tail
/// (the cell does the same with `replaceTail`). Main thread only.
final class StreamingMeasurer {
    nonisolated(unsafe) static let main = StreamingMeasurer()

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    private var rowId = ""
    private var blocks: [String] = []
    private var starts: [Int] = []

    init() {
        // The same set-up as TextMeasurer, so the heights match exactly.
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
    }

    func measure(rowId: String, _ rendered: MarkdownRenderer.Rendered, width: CGFloat) -> NSSize {
        let string = rendered.string
        guard string.length > 0 else { return .zero }
        let width = max(1, width)
        var replaced = false
        if rowId == self.rowId, container.size.width == width, !blocks.isEmpty {
            var common = 0
            while common < min(blocks.count, rendered.blocks.count) - 1, blocks[common] == rendered.blocks[common] {
                common += 1
            }
            let start = rendered.starts.indices.contains(common) ? rendered.starts[common] : 0
            let oldStart = starts.indices.contains(common) ? starts[common] : 0
            if start == oldStart, start <= storage.length, start <= string.length {
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start),
                                          with: string.attributedSubstring(from: NSRange(location: start, length: string.length - start)))
                storage.endEditing()
                replaced = true
            }
        }
        if !replaced {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            storage.setAttributedString(string)
        }
        self.rowId = rowId
        blocks = rendered.blocks
        starts = rendered.starts
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }
}

enum RowRenderer {
    static func render(_ row: TranscriptRow, expanded: Bool, showAll: Bool = false, tableWidth: CGFloat, measurer: TextMeasurer) -> RowRender {
        let width = RowMetrics.column(for: row, tableWidth: tableWidth).width
        let vertical = RowMetrics.rowTop + RowMetrics.rowBottom
        switch row.content {
        case .user(let message) where message.isFromRunner:
            let text = runnerMessageText(message.text)
            let size = measurer.measure(text, width: width)
            return RowRender(height: RowMetrics.runnerTop + size.height + RowMetrics.runnerBottom, text: text, textSize: size)

        case .user(let message):
            let maxText = floor(width * RowMetrics.bubbleShare) - RowMetrics.bubblePadH * 2
            let text = NSAttributedString(string: message.text.isEmpty ? " " : message.text, attributes: Theme.text())
            let size = measurer.measure(text, width: maxText)
            let (frames, area) = imageFrames(message.images, maxWidth: floor(width * RowMetrics.bubbleShare),
                                             maxHeight: RowMetrics.userThumbHeight, alignRight: true)
            let showText = !message.text.isEmpty || message.images.isEmpty
            let imageBlock = message.images.isEmpty ? 0 : area + (showText ? RowMetrics.imageGap : 0)
            let bubble = showText ? size.height + RowMetrics.bubblePadV * 2 : 0
            return RowRender(height: RowMetrics.userTop + imageBlock + bubble + RowMetrics.userBottom,
                             text: showText ? text : nil, textSize: size, imageFrames: frames, imageAreaHeight: area)

        case .assistant(let item):
            let rendered = MarkdownRenderer.render(item.text)
            // While a reply streams, each flush measures only what changed
            // since the last one (the finished blocks keep their layout).
            // Measuring the whole message every flush was 61% of the main
            // thread in a long pinned stream, growing with the message.
            var size = item.isStreaming && Thread.isMainThread
                ? StreamingMeasurer.main.measure(rowId: row.id, rendered, width: width)
                : measurer.measure(rendered.string, width: width)
            size.height += rendered.trailingPad
            // Only a streaming row needs its blocks (for in-place updates);
            // a finished one would just hold a second copy of its markdown.
            return RowRender(height: RowMetrics.rowTop + size.height + 10, text: rendered.string, textSize: size,
                             blocks: item.isStreaming ? rendered.blocks : [], blockStarts: item.isStreaming ? rendered.starts : [])

        case .reasoning(let item):
            let header = headerText(title: item.isStreaming ? "Thinking" : "Thought", subtitle: WorkSummary.thought(item.text))
            let headerSize = header.size()
            guard expanded else { return RowRender(height: RowMetrics.workHeight, text: header, textSize: headerSize) }
            let body = NSAttributedString(string: item.text, attributes: Theme.text(Theme.workFont, color: Theme.quietText, line: 21, spacing: 6))
            let size = measurer.measure(body, width: width - RowMetrics.titleIndent)
            return RowRender(height: RowMetrics.workHeight + size.height + 12, text: header, textSize: headerSize, detail: body, detailSize: size)

        case .tool(let tool):
            let header = toolHeader(tool)
            let headerSize = header.size()
            // An edit is one line with its +N -M that opens on a click, like
            // every other tool: open groups used to pour out every diff at
            // 12 lines each, and the changes card shows them again anyway.
            guard expanded else { return RowRender(height: RowMetrics.workHeight, text: header, textSize: headerSize) }
            if row.kind == .diff, let diff = tool.effectiveDiff, !diff.hunks.isEmpty {
                let body = showAll
                    ? diffWithNote([diff], maxLines: RowMetrics.maxDiffLines)
                    : diffWithNote([diff], maxLines: previewLines([diff]), more: DiffPreview.allKey(row.id))
                let size = measurer.measure(body, width: width - RowMetrics.titleIndent - 1)
                let box = size.height + RowMetrics.diffPadV * 2
                return RowRender(height: RowMetrics.workHeight + box + 10, text: header, textSize: headerSize, detail: body, detailSize: size)
            }
            let body = toolBody(tool)
            let size = measurer.measure(body, width: width - RowMetrics.titleIndent - RowMetrics.boxPad * 2)
            return RowRender(height: RowMetrics.workHeight + size.height + RowMetrics.boxPad * 2 + 10, text: header, textSize: headerSize, detail: body, detailSize: size)

        case .images(_, let images):
            let (frames, area) = imageFrames(images, maxWidth: width, maxHeight: RowMetrics.gridMaxHeight, alignRight: false)
            return RowRender(height: vertical + 2 + area, imageFrames: frames, imageAreaHeight: area)

        case .approval(let item):
            if let resolution = item.resolution {
                // Settled, it's one quiet work line ("Allowed  Write
                // release.sh") that opens to what was asked, like a tool
                // row. As a full card it was as loud as one still waiting,
                // and the write it allowed followed it straight away.
                let header = resolvedApprovalText(item.request, resolution)
                let headerSize = header.size()
                guard expanded, item.opens else { return RowRender(height: RowMetrics.workHeight, text: header, textSize: headerSize) }
                let body = approvalPayload(item.request)
                let size = measurer.measure(body, width: width - RowMetrics.titleIndent - RowMetrics.boxPad * 2)
                return RowRender(height: RowMetrics.workHeight + size.height + RowMetrics.boxPad * 2 + 10, text: header, textSize: headerSize,
                                 detail: body, detailSize: size)
            }
            let inner = width - RowMetrics.cardPad * 2 - RowMetrics.accentBar
            let title = approvalTitleText(item)
            let titleSize = measurer.measure(title, width: inner)
            let payload = approvalPayload(item.request)
            let payloadSize = measurer.measure(payload, width: inner - RowMetrics.boxPad * 2)
            let height = RowMetrics.cardPad * 2 + titleSize.height + 10 + payloadSize.height + RowMetrics.boxPad * 2 + 12 + RowMetrics.buttonHeight
            return RowRender(height: vertical + 4 + height, text: title, textSize: titleSize, detail: payload, detailSize: payloadSize)

        case .question(let item):
            let inner = width - RowMetrics.cardPad * 2 - RowMetrics.accentBar
            var total = RowMetrics.cardPad * 2
            var textHeights: [CGFloat] = []
            let answered = item.resolution != nil
            for question in item.request.questions {
                let textHeight = measurer.measure(questionText(question.question, answered: answered), width: inner).height
                textHeights.append(textHeight)
                total += answered ? textHeight + RowMetrics.answeredGap : questionHeight(question, textHeight: textHeight)
            }
            guard let resolution = item.resolution else {
                total += RowMetrics.otherFieldHeight + 2 + 12 + RowMetrics.buttonHeight
                return RowRender(height: vertical + 4 + total, lineHeights: textHeights)
            }
            // Answered: the question and the answer, not every option
            // greyed out with none of them ticked.
            total += RowMetrics.answerHeight
            return RowRender(height: vertical + 4 + total, text: answerText(resolution), lineHeights: textHeights)

        case .plan(let entries):
            let text = planText(entries)
            let size = measurer.measure(text, width: width - RowMetrics.cardPad * 2)
            return RowRender(height: vertical + 4 + size.height + RowMetrics.cardPad * 2 - 4, text: text, textSize: size)

        case .footer(let completion):
            return RowRender(height: RowMetrics.footerHeight, text: footerText(completion))

        case .note(let note):
            if row.inGroup {
                let header = headerText(title: firstLine(note), subtitle: "")
                return RowRender(height: RowMetrics.workHeight, text: header, textSize: header.size())
            }
            let text = NSAttributedString(string: note, attributes: Theme.text(Theme.smallFont, color: Theme.quietText, line: 17, alignment: .center))
            let size = measurer.measure(text, width: width)
            return RowRender(height: vertical + size.height, text: text, textSize: size)

        case .error(let message):
            let text = NSAttributedString(string: message, attributes: Theme.text(color: .systemRed))
            let size = measurer.measure(text, width: width - RowMetrics.boxPad * 2)
            return RowRender(height: vertical + size.height + RowMetrics.boxPad * 2, text: text, textSize: size)

        case .group(let group):
            let text = groupText(group)
            return RowRender(height: RowMetrics.workHeight, text: text, textSize: text.size())

        case .working:
            return RowRender(height: RowMetrics.workingHeight)

        case .changes(let card):
            return changesRender(card, width: width, measurer: measurer)
        }
    }

    /// The resume the runner sends after a restart, as a note rather than a
    /// bubble: it wasn't Mike talking. The first line says where it came
    /// from; the message itself is under it, since the agent acts on it.
    static func runnerMessageText(_ message: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Sent by the runner after it restarted",
                                             attributes: Theme.text(Theme.smallFont, color: Theme.faintText, line: 17, alignment: .center))
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            text.append(NSAttributedString(string: "\n" + body, attributes: Theme.text(Theme.labelFont, color: Theme.quietText, line: 19, alignment: .center)))
        }
        return text
    }

    // MARK: Work lines

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 200 ? String(line.prefix(200)) : line
    }

    static func clampLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > count else { return text }
        return lines.prefix(count).joined(separator: "\n") + "\n…"
    }

    static var truncating: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    static func headerText(title: String, subtitle: String) -> NSAttributedString {
        let style = truncating
        let output = NSMutableAttributedString(string: title, attributes: [
            .font: Theme.workFont, .foregroundColor: Theme.quietText, .paragraphStyle: style,
        ])
        if !subtitle.isEmpty {
            output.append(NSAttributedString(string: "  " + subtitle, attributes: [
                .font: Theme.workFont, .foregroundColor: Theme.faintText, .paragraphStyle: style,
            ]))
        }
        return output
    }

    static func groupText(_ group: ThreadbareCore.WorkGroup) -> NSAttributedString {
        let style = truncating
        let output = NSMutableAttributedString(string: group.summary, attributes: [
            .font: Theme.workFont, .foregroundColor: Theme.quietText, .paragraphStyle: style,
        ])
        if group.failedCount > 0 {
            output.append(NSAttributedString(string: ", \(group.failedCount) failed", attributes: [
                .font: Theme.workFont, .foregroundColor: Theme.failed, .paragraphStyle: style,
            ]))
        }
        if group.isLive, let action = group.currentAction {
            // What's happening now is what Mike watches while a turn runs,
            // so it's the brightest work text on screen: the summary before
            // it stays quiet and the dot faint, as Codex and T3 do.
            output.append(NSAttributedString(string: "  ·  ", attributes: [
                .font: Theme.workFont, .foregroundColor: Theme.faintText, .paragraphStyle: style,
            ]))
            output.append(NSAttributedString(string: ToolPresentation.shortTitle(action, limit: 90), attributes: [
                .font: Theme.workFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
        }
        return output
    }

    /// "Allowed  Write release.sh": the decision, then what it was for.
    static func resolvedApprovalText(_ request: ApprovalRequest, _ resolution: ApprovalResolution) -> NSAttributedString {
        let style = truncating
        let output = NSMutableAttributedString(string: ApprovalText.decision(resolution.decision), attributes: [
            .font: Theme.workFont, .foregroundColor: Theme.faintText, .paragraphStyle: style,
        ])
        if resolution.decision != .expired {
            output.append(NSAttributedString(string: "  " + ApprovalText.target(request), attributes: [
                .font: Theme.workFont, .foregroundColor: Theme.quietText, .paragraphStyle: style,
            ]))
        }
        return output
    }

    static func toolHeader(_ tool: ToolItem) -> NSAttributedString {
        let style = truncating
        // A failure is marked once, by the red icon; the title stays in the
        // work line colour rather than the row turning red all over.
        let color = Theme.quietText
        let output: NSMutableAttributedString
        if let file = ToolPresentation.fileTitle(tool) {
            // "Read UploadTask.swift  Sources/Upload": the file, then its
            // folder dimmed, as in the changes card. The whole path is the
            // row's tooltip.
            output = NSMutableAttributedString(string: file.verb + " " + file.name, attributes: [
                .font: Theme.workFont, .foregroundColor: color, .paragraphStyle: style,
            ])
            if !file.folder.isEmpty {
                output.append(NSAttributedString(string: "  " + file.folder, attributes: [
                    .font: Theme.detailFont, .foregroundColor: Theme.faintText, .paragraphStyle: style,
                ]))
            }
        } else {
            output = NSMutableAttributedString(string: ToolPresentation.shortTitle(tool.title), attributes: [
                .font: Theme.workFont, .foregroundColor: color, .paragraphStyle: style,
            ])
        }
        if let diff = tool.effectiveDiff, !diff.hunks.isEmpty {
            let stats = DiffBuilder.stats(diff)
            output.append(statsText(added: stats.added, removed: stats.removed, leading: "  "))
        }
        return output
    }

    static func statsText(added: Int, removed: Int, leading: String = "") -> NSAttributedString {
        let output = NSMutableAttributedString(string: leading + "+\(added)", attributes: [.font: Theme.statsFont, .foregroundColor: Theme.addedText])
        output.append(NSAttributedString(string: " −\(removed)", attributes: [.font: Theme.statsFont, .foregroundColor: Theme.removedText]))
        return output
    }

    // MARK: Expanded tools

    static let monoFont = Theme.outputFont

    static func mono(_ text: String, _ color: NSColor) -> NSAttributedString {
        let (style, offset) = Theme.lines(TypeScale.outputLine, font: monoFont)
        style.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: offset])
    }

    /// An empty line `height` tall, for a little space between parts.
    static func gap(_ height: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 2)
        let (style, _) = Theme.lines(height, font: font)
        return NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style])
    }

    /// What an expanded tool shows: a command and its output, a file with
    /// line numbers, a search and its matches, or the input as fields.
    static func toolBody(_ tool: ToolItem) -> NSAttributedString {
        let output = NSMutableAttributedString()
        // Output is ordinary text even when the tool failed: in red it read
        // as removed code and was the loudest thing in the window. Only the
        // lines that say what went wrong are marked.
        let outputColor = Theme.quietText
        var hasOutput = false
        func appendOutput(_ text: String) {
            guard !text.isEmpty else { return }
            hasOutput = true
            if output.length > 0 {
                output.append(mono("\n", outputColor))
                output.append(gap(8))
            }
            guard tool.failed else { return output.append(mono(text, outputColor)) }
            // Runs of lines in one colour, so long output stays a few runs.
            var run: [Substring] = []
            var runIsError = false
            func flush() {
                guard !run.isEmpty else { return }
                output.append(mono(run.joined(separator: "\n"), runIsError ? Theme.failed : outputColor))
                run = []
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let isError = ToolPresentation.isErrorLine(line)
                if !run.isEmpty, isError != runIsError {
                    flush()
                    output.append(mono("\n", outputColor))
                }
                runIsError = isError
                run.append(line)
            }
            flush()
        }
        switch ToolPresentation.detail(tool) {
        case .command(let command, let result):
            output.append(mono("$ ", Theme.faintText))
            output.append(mono(clampLines(command, 40), .labelColor))
            appendOutput(result)
        case .file(_, let lines):
            // Just the lines: the row's title already names the file (and
            // its tooltip has the whole path).
            if !lines.isEmpty {
                hasOutput = true
                output.append(numbered(lines))
            }
        case .search(let query, let scope, let result):
            output.append(mono(query, .labelColor))
            if let scope { output.append(mono("  in " + scope, Theme.faintText)) }
            appendOutput(result)
        case .fields(let fields, let result):
            output.append(fieldsText(fields))
            appendOutput(result)
        }
        if tool.result?.truncated == true {
            output.append(mono("\n", .labelColor))
            output.append(gap(6))
            output.append(NSAttributedString(string: "Output shortened", attributes: Theme.text(Theme.smallFont, color: Theme.faintText, line: 17)))
        } else if !hasOutput {
            if output.length > 0 { output.append(mono("\n", .labelColor)) }
            output.append(mono(tool.isFinished ? "No output" : "Running…", Theme.faintText))
        }
        return output
    }

    /// Tool input as "key:  value" lines with the values in one column (a
    /// tab stop past the widest key, up to a cap) and long values wrapping
    /// under their value rather than back under the key.
    static func fieldsText(_ fields: [ToolPresentation.Field]) -> NSAttributedString {
        let keyWidth = ToolPresentation.keyWidth(fields)
        let column = CGFloat(keyWidth + 2) * Theme.digitWidth(monoFont)
        let (style, offset) = Theme.lines(TypeScale.outputLine, font: monoFont, head: column, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        style.lineBreakMode = .byCharWrapping
        let key: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: Theme.faintText, .paragraphStyle: style, .baselineOffset: offset]
        var value = key
        value[.foregroundColor] = NSColor.labelColor
        let output = NSMutableAttributedString()
        for (index, field) in fields.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: value)) }
            // A key past the cap runs on into its value instead.
            let label = field.key + ":"
            output.append(NSAttributedString(string: label + (label.count > keyWidth ? " " : "\t"), attributes: key))
            output.append(NSAttributedString(string: field.value, attributes: value))
        }
        return output
    }

    /// File lines with their numbers right-aligned in a gutter.
    static func numbered(_ lines: [ToolPresentation.NumberedLine]) -> NSAttributedString {
        let digits = max(3, String(lines.compactMap(\.number).max() ?? 0).count)
        let gutter = CGFloat(digits) * Theme.digitWidth(monoFont) + 2
        // Wrapped lines hang under the text, past the number.
        let (style, offset) = Theme.lines(TypeScale.outputLine, font: monoFont, head: gutter + 14, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .right, location: gutter), NSTextTab(textAlignment: .left, location: gutter + 14)]
        style.lineBreakMode = .byCharWrapping
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: Theme.faintText, .paragraphStyle: style, .baselineOffset: offset]
        let textAttributes: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: Theme.quietText, .paragraphStyle: style, .baselineOffset: offset]
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: textAttributes)) }
            output.append(NSAttributedString(string: "\t" + (line.number.map(String.init) ?? "") + "\t", attributes: numberAttributes))
            output.append(NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: textAttributes))
        }
        return output
    }

    // MARK: Diffs

    /// A diff and, if it was cut short, what was left out: "Show 30 more
    /// lines", which opens the rest through the expansion key `more`, or
    /// with no key (all of it is already open, up to the cap) a quiet note.
    static func diffWithNote(_ diffs: [EditDiff], maxLines: Int, inset: CGFloat = 10, more: String? = nil) -> NSAttributedString {
        let (diff, hidden) = diffText(diffs, maxLines: maxLines, inset: inset)
        guard hidden > 0 else { return diff }
        let body = NSMutableAttributedString(attributedString: diff)
        let lines = hidden == 1 ? "1 more line" : "\(hidden) more lines"
        if let more {
            let (style, offset) = Theme.lines(26, font: Theme.detailFont, head: inset, first: inset)
            let link: [NSAttributedString.Key: Any] = [.font: Theme.detailFont, .foregroundColor: Theme.quietText, .paragraphStyle: style,
                                                       .baselineOffset: offset, .tbAction: more, .cursor: NSCursor.pointingHand]
            body.append(NSAttributedString(string: "\n", attributes: [.font: Theme.detailFont, .paragraphStyle: style]))
            body.append(NSAttributedString(string: "Show " + lines, attributes: link))
        } else {
            let (style, offset) = Theme.lines(24, font: Theme.smallFont, head: inset, first: inset)
            let note: [NSAttributedString.Key: Any] = [.font: Theme.smallFont, .foregroundColor: Theme.faintText, .paragraphStyle: style, .baselineOffset: offset]
            body.append(NSAttributedString(string: "\n", attributes: note))
            body.append(NSAttributedString(string: lines + " not shown", attributes: note))
        }
        return body
    }

    /// How many lines of `diffs` a diff opened short shows (a break between
    /// two diffs counts as a line, as `diffText` draws it).
    static func previewLines(_ diffs: [EditDiff]) -> Int {
        let total = diffs.reduce(0) { $0 + DiffBuilder.displayLines($1).count } + max(0, diffs.count - 1)
        return DiffPreview.shown(of: total)
    }

    /// Diff lines with line numbers and the +/− sign in a quiet gutter, on
    /// faint tints. Returns the text and how many lines were left out.
    static func diffText(_ diffs: [EditDiff], maxLines: Int, inset: CGFloat = 10) -> (NSAttributedString, hidden: Int) {
        var lines: [DiffDisplayLine] = []
        var hidden = 0
        for (index, diff) in diffs.enumerated() {
            let room = maxLines - lines.count
            guard room > 0 else {
                hidden += DiffBuilder.displayLines(diff).count
                continue
            }
            if index > 0 { lines.append(DiffDisplayLine(kind: .hunkHeader, text: "")) }
            for line in DiffBuilder.displayLines(diff, maxLines: room) {
                if line.kind == .elided {
                    hidden += Int(line.text.split(separator: " ").first ?? "") ?? 0
                } else {
                    lines.append(line)
                }
            }
        }
        let numbers = lines.compactMap { $0.newNumber ?? $0.oldNumber }
        let digits = max(2, String(numbers.max() ?? 0).count)
        let numberEnd = inset + CGFloat(digits) * Theme.digitWidth(Theme.diffFont)
        // A new file is all additions: shown as plain content with green
        // signs rather than a solid green slab, the loudest thing on screen.
        let newFile = lines.allSatisfy { $0.kind != .removed && $0.kind != .context }
        let signAt = numberEnd + 10
        let textAt = signAt + 14
        // Wrapped lines stop as far from the box's right edge as the
        // numbers start from its left; they ran right up to the border.
        let (style, offset) = Theme.lines(Theme.diffLine, font: Theme.diffFont, head: textAt, first: 0, tail: -inset)
        style.tabStops = [NSTextTab(textAlignment: .right, location: numberEnd), NSTextTab(textAlignment: .left, location: signAt),
                          NSTextTab(textAlignment: .left, location: textAt)]
        style.lineBreakMode = .byCharWrapping
        let gutter: [NSAttributedString.Key: Any] = [.font: Theme.diffFont, .foregroundColor: Theme.faintText, .paragraphStyle: style, .baselineOffset: offset]
        let body: [NSAttributedString.Key: Any] = [.font: Theme.diffFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style, .baselineOffset: offset]

        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: body)) }
            let start = output.length
            let number: Int?
            let sign: String
            let background: NSColor?
            switch line.kind {
            case .added: number = line.newNumber; sign = "+"; background = newFile ? nil : Theme.addedBackground
            // One column of new-file numbers that only counts up: a removed
            // line's old number made it run 20, 20, ... 27, 25.
            case .removed: number = nil; sign = "−"; background = Theme.removedBackground
            case .context: number = line.newNumber; sign = ""; background = nil
            case .hunkHeader, .elided: number = nil; sign = ""; background = nil
            }
            if line.kind == .hunkHeader {
                // A quiet break between hunks rather than the @@ header.
                output.append(NSAttributedString(string: "\t\t⋯", attributes: gutter))
                continue
            }
            output.append(NSAttributedString(string: "\t" + (number.map(String.init) ?? "") + "\t", attributes: gutter))
            var signAttributes = gutter
            if newFile { signAttributes[.foregroundColor] = Theme.addedText }
            output.append(NSAttributedString(string: sign + "\t", attributes: signAttributes))
            output.append(NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: body))
            if let background {
                output.addAttribute(.tbLineBackground, value: background, range: NSRange(location: start, length: output.length - start))
            }
        }
        return (output, hidden)
    }

    // MARK: Changes card

    static func changesRender(_ card: ChangedFiles, width: CGFloat, measurer: TextMeasurer) -> RowRender {
        let title = NSAttributedString(string: card.title, attributes: [.font: Theme.changesTitleFont, .foregroundColor: NSColor.labelColor])
        let total = statsText(added: card.added, removed: card.removed)
        var parts: [RowRender.Part] = []
        var height = RowMetrics.changesHeader
        for file in card.files {
            let line = NSMutableAttributedString(string: file.name, attributes: [.font: Theme.workFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
            if !file.folder.isEmpty {
                line.append(NSAttributedString(string: "  " + file.folder, attributes: [.font: Theme.detailFont, .foregroundColor: Theme.faintText, .paragraphStyle: truncating]))
            }
            var part = RowRender.Part(leading: line, trailing: statsText(added: file.added, removed: file.removed))
            height += RowMetrics.changesFile
            if file.isExpanded {
                let key = ChangedFiles.expansionKey(turnId: card.turnId, path: file.path)
                let body = file.showsAll
                    ? diffWithNote(file.diffs, maxLines: 600, inset: RowMetrics.cardPad)
                    : diffWithNote(file.diffs, maxLines: previewLines(file.diffs), inset: RowMetrics.cardPad, more: DiffPreview.allKey(key))
                part.body = body
                part.bodyHeight = measurer.measure(body, width: width - 1).height + 8
                height += part.bodyHeight
            }
            parts.append(part)
        }
        height += 6
        return RowRender(height: 8 + height + 6, text: title, detail: total, parts: parts)
    }

    // MARK: Cards

    /// "Write release.sh?" and, for a file, its folder after it, dimmed, as
    /// file rows show it. The card's tooltip has the whole path.
    static func approvalTitleText(_ item: ApprovalItem) -> NSAttributedString {
        var attributes = Theme.text(Theme.cardTitleFont, line: 20)
        let output = NSMutableAttributedString(string: ApprovalText.title(item.request), attributes: attributes)
        if let path = ApprovalText.filePath(item.request) {
            let folder = PathDisplay.folder(of: path, relativeTo: item.root)
            if !folder.isEmpty {
                // Same line height and baseline offset as the title, so the
                // smaller run sits on its baseline.
                attributes[.font] = Theme.detailFont
                attributes[.foregroundColor] = Theme.faintText
                output.append(NSAttributedString(string: "  " + folder, attributes: attributes))
            }
        }
        return output
    }

    /// The command, the start of what would be written to a file, the page,
    /// or the tool's input, in a monospaced block. The file's name and
    /// folder are in the title above it.
    static func approvalPayload(_ request: ApprovalRequest) -> NSAttributedString {
        let input = request.input
        if let command = input["command"]?.stringValue {
            return mono(clampLines(command, 12), .labelColor)
        }
        if ApprovalText.filePath(request) != nil {
            let call = ToolCall(itemId: request.approvalId, name: request.name, kind: request.name == "Write" ? .write : .edit,
                                title: request.title, input: input)
            if let diff = DiffBuilder.diff(forTool: call), !diff.hunks.isEmpty {
                return diffText([diff], maxLines: 8, inset: 0).0
            }
            return mono(ToolPresentation.shortTitle(ApprovalText.filePath(request) ?? "", limit: 300), Theme.quietText)
        }
        if let url = input["url"]?.stringValue {
            return mono(url, .labelColor)
        }
        let fields = ToolPresentation.fields(input)
        if fields.isEmpty { return mono(clampLines(request.title, 10), .labelColor) }
        return fieldsText(Array(fields.prefix(8)))
    }

    /// A question's text: card title weight, quieter once it's answered so
    /// the answer under it is the brighter line.
    static func questionText(_ question: String, answered: Bool = false) -> NSAttributedString {
        NSAttributedString(string: question, attributes: Theme.text(Theme.cardTitleFont, color: answered ? Theme.quietText : .labelColor, line: 20))
    }

    /// What an answered question card says under the question: the answer
    /// (sent as the resolution's message), or how it ended.
    static func answerText(_ resolution: ApprovalResolution) -> NSAttributedString {
        let message = resolution.message.flatMap { firstLine($0).isEmpty ? nil : firstLine($0) }
        let text = resolution.decision == .answered ? (message ?? "Answered") : ApprovalText.decision(resolution.decision)
        let color: NSColor = resolution.decision == .answered ? .labelColor : Theme.quietText
        return NSAttributedString(string: text, attributes: [.font: Theme.workFont, .foregroundColor: color, .paragraphStyle: truncating])
    }

    static func questionHeight(_ question: Question, textHeight: CGFloat) -> CGFloat {
        // The question's short `header` isn't shown: it would read as an eyebrow label.
        var height: CGFloat = textHeight + 8
        for option in question.options {
            height += RowMetrics.optionHeight
            if let description = option.description, !description.isEmpty { height += RowMetrics.optionDescription }
        }
        return height + 12
    }

    /// "2 of 5 steps done", then the steps. Every card starts with a
    /// one-line title; without one the plan read as an orphaned box of
    /// struck-through lines.
    static func planText(_ entries: [PlanEntry]) -> NSAttributedString {
        let (titleStyle, titleOffset) = Theme.lines(TypeScale.workLine, font: Theme.changesTitleFont, spacing: 8)
        let output = NSMutableAttributedString(string: PlanSummary.title(entries), attributes: [
            .font: Theme.changesTitleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: titleStyle, .baselineOffset: titleOffset,
        ])
        let font = Theme.bodyFont
        let (style, offset) = Theme.lines(22, font: font, spacing: 4, head: 24, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        output.append(NSAttributedString(string: "\n", attributes: [.font: Theme.changesTitleFont, .paragraphStyle: titleStyle]))
        for (index, entry) in entries.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style, .baselineOffset: offset])) }
            let (mark, color, textColor): (String, NSColor, NSColor) = switch entry.status {
            case .completed: ("✓", Theme.addedText, .secondaryLabelColor)
            case .in_progress: ("●", .controlAccentColor, .labelColor)
            case .pending: ("○", Theme.faintText, .labelColor)
            }
            output.append(NSAttributedString(string: mark + "\t", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: offset]))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: style, .baselineOffset: offset]
            if entry.status == .completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: entry.text, attributes: attributes))
        }
        return output
    }

    static func footerText(_ completion: TurnCompletion) -> NSAttributedString {
        var parts: [String] = []
        switch completion.outcome {
        case .completed: parts.append(RelativeTime.duration(milliseconds: completion.durationMs))
        case .interrupted: parts.append("Stopped after \(RelativeTime.duration(milliseconds: completion.durationMs))")
        case .failed: parts.append("Failed after \(RelativeTime.duration(milliseconds: completion.durationMs))")
        }
        if let cost = CostText.format(completion.costUsd) { parts.append(cost) }
        var text = parts.joined(separator: " · ")
        if let error = completion.error, !error.isEmpty { text += ": " + firstLine(error) }
        return NSAttributedString(string: text, attributes: [
            .font: Theme.smallFont,
            .foregroundColor: completion.outcome == .failed ? NSColor.systemRed : Theme.faintText,
            .paragraphStyle: truncating,
        ])
    }

    // MARK: Images

    /// Lays images out in rows, each fitted to `maxHeight` and the grid's
    /// cell width, with the images in a row at one height
    /// (`ImageLayout`).
    static func imageFrames(_ images: [ImageRef], maxWidth: CGFloat, maxHeight: CGFloat, alignRight: Bool) -> ([NSRect], CGFloat) {
        let layout = ImageLayout.frames(sizes: images.map(pixelSize), maxWidth: maxWidth, maxHeight: maxHeight,
                                        cellWidth: RowMetrics.gridMaxWidth, gap: RowMetrics.imageGap, alignRight: alignRight)
        return (layout.frames, layout.height)
    }

    nonisolated(unsafe) private static let sizeCache = NSCache<NSString, NSValue>()

    static func pixelSize(_ image: ImageRef) -> NSSize {
        if let width = image.width, let height = image.height, width > 0, height > 0 {
            return NSSize(width: width, height: height)
        }
        if let cached = sizeCache.object(forKey: image.path as NSString) { return cached.sizeValue }
        var size = NSSize(width: 160, height: 120)
        if let header = ImageSize.read(path: image.path) {
            size = NSSize(width: header.width, height: header.height)
        }
        sizeCache.setObject(NSValue(size: size), forKey: image.path as NSString)
        return size
    }
}
