import AppKit
import Synchronization
import ThreadbareCore

/// Layout numbers shared by height measurement and the cell views, so the
/// two always agree.
enum RowMetrics {
    static let rowTop: CGFloat = 6
    static let rowBottom: CGFloat = 6
    /// Space above a user message, which starts a turn.
    static let userTop: CGFloat = 18
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
    static let otherFieldHeight: CGFloat = 26
    static let userThumbHeight: CGFloat = 120
    static let gridMaxHeight: CGFloat = 240
    static let gridMaxWidth: CGFloat = 320
    static let imageGap: CGFloat = 8
    /// The most lines an opened diff shows in the flow.
    static let maxDiffLines = 1500
    static let footerHeight: CGFloat = 27
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

    /// Keyed by the reading column's width, which is all a render depends
    /// on: tables of different widths with the column at its widest share
    /// renders, so a sidebar drag or a scroller appearing costs nothing.
    static func key(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> NSString {
        let open = effectiveExpanded(row, expanded) ? 1 : 0
        return "\(row.id)|\(row.version)|\(open)|\(row.inGroup ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))" as NSString
    }

    func cached(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> RowRender? {
        cache.object(forKey: Self.key(row, expanded: expanded, width: width))
    }

    func render(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> RowRender {
        let key = Self.key(row, expanded: expanded, width: width)
        if let hit = cache.object(forKey: key) { return hit }
        let render = RowRenderer.render(row, expanded: Self.effectiveExpanded(row, expanded), tableWidth: width, measurer: .current)
        store(render, key: key, row: row, expanded: expanded, width: width)
        return render
    }

    func store(_ render: RowRender, for row: TranscriptRow, expanded: Bool, width: CGFloat) {
        store(render, key: Self.key(row, expanded: expanded, width: width), row: row, expanded: expanded, width: width)
    }

    private func store(_ render: RowRender, key: NSString, row: TranscriptRow, expanded: Bool, width: CGFloat) {
        cache.setObject(render, forKey: key, cost: Self.cost(render))
        let slot = "\(row.id)|\(Self.effectiveExpanded(row, expanded) ? 1 : 0)|\(row.inGroup ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))"
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
        let missing = rows.filter { cached($0, expanded: expanded.contains($0.id), width: width) == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: missing.count) { index in
            let row = missing[index]
            _ = render(row, expanded: expanded.contains(row.id), width: width)
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
    static func render(_ row: TranscriptRow, expanded: Bool, tableWidth: CGFloat, measurer: TextMeasurer) -> RowRender {
        let width = RowMetrics.column(for: row, tableWidth: tableWidth).width
        let vertical = RowMetrics.rowTop + RowMetrics.rowBottom
        switch row.content {
        case .user(let message):
            let maxText = floor(width * RowMetrics.bubbleShare) - RowMetrics.bubblePadH * 2
            let text = NSAttributedString(string: message.text.isEmpty ? " " : message.text, attributes: Theme.text())
            let size = measurer.measure(text, width: maxText)
            let (frames, area) = imageFrames(message.images, maxWidth: floor(width * RowMetrics.bubbleShare),
                                             maxHeight: RowMetrics.userThumbHeight, alignRight: true)
            let showText = !message.text.isEmpty || message.images.isEmpty
            let imageBlock = message.images.isEmpty ? 0 : area + (showText ? RowMetrics.imageGap : 0)
            let bubble = showText ? size.height + RowMetrics.bubblePadV * 2 : 0
            return RowRender(height: RowMetrics.userTop + imageBlock + bubble + RowMetrics.rowBottom + 4,
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
            let header = headerText(title: item.isStreaming ? "Thinking" : "Thought", subtitle: firstLine(item.text))
            let headerSize = header.size()
            guard expanded else { return RowRender(height: RowMetrics.workHeight, text: header, textSize: headerSize) }
            let body = NSAttributedString(string: item.text, attributes: Theme.text(Theme.workFont, color: .secondaryLabelColor, line: 21, spacing: 6))
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
                let body = diffWithNote([diff], maxLines: RowMetrics.maxDiffLines)
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
            let inner = width - RowMetrics.cardPad * 2 - RowMetrics.accentBar
            let title = NSAttributedString(string: approvalTitle(item.request), attributes: Theme.text(Theme.cardTitleFont, line: 20))
            let titleSize = measurer.measure(title, width: inner)
            let payload = approvalPayload(item.request)
            let payloadSize = measurer.measure(payload, width: inner - RowMetrics.boxPad * 2)
            let actions = item.resolution == nil ? RowMetrics.buttonHeight : 17
            let height = RowMetrics.cardPad * 2 + titleSize.height + 10 + payloadSize.height + RowMetrics.boxPad * 2 + 12 + actions
            return RowRender(height: vertical + 4 + height, text: title, textSize: titleSize, detail: payload, detailSize: payloadSize)

        case .question(let item):
            let inner = width - RowMetrics.cardPad * 2 - RowMetrics.accentBar
            var total = RowMetrics.cardPad * 2
            var textHeights: [CGFloat] = []
            for question in item.request.questions {
                let textHeight = measurer.measure(questionText(question.question), width: inner).height
                textHeights.append(textHeight)
                total += questionHeight(question, textHeight: textHeight)
            }
            total += item.resolution == nil ? (RowMetrics.otherFieldHeight + 2 + 12 + RowMetrics.buttonHeight) : 17
            return RowRender(height: vertical + 4 + total, lineHeights: textHeights)

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
            let text = NSAttributedString(string: note, attributes: Theme.text(Theme.smallFont, color: .secondaryLabelColor, line: 17, alignment: .center))
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
            .font: Theme.workFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
        if !subtitle.isEmpty {
            output.append(NSAttributedString(string: "  " + subtitle, attributes: [
                .font: Theme.workFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
            ]))
        }
        return output
    }

    static func groupText(_ group: ThreadbareCore.WorkGroup) -> NSAttributedString {
        let style = truncating
        let output = NSMutableAttributedString(string: group.summary, attributes: [
            .font: Theme.workFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
        if group.failedCount > 0 {
            output.append(NSAttributedString(string: ", \(group.failedCount) failed", attributes: [
                .font: Theme.workFont, .foregroundColor: Theme.removedText, .paragraphStyle: style,
            ]))
        }
        if group.isLive, let action = group.currentAction {
            // What's happening now is what Mike watches while a turn runs:
            // readable secondary text, with only the dot kept faint.
            output.append(NSAttributedString(string: "  ·  ", attributes: [
                .font: Theme.workFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
            ]))
            output.append(NSAttributedString(string: ToolPresentation.shortTitle(action, limit: 90), attributes: [
                .font: Theme.workFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
        }
        return output
    }

    static func toolHeader(_ tool: ToolItem) -> NSAttributedString {
        let style = truncating
        let color = tool.failed ? Theme.removedText : NSColor.secondaryLabelColor
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
                    .font: Theme.detailFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
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
        let outputColor: NSColor = tool.failed ? Theme.removedText : .secondaryLabelColor
        var hasOutput = false
        func appendOutput(_ text: String) {
            guard !text.isEmpty else { return }
            hasOutput = true
            if output.length > 0 {
                output.append(mono("\n", outputColor))
                output.append(gap(8))
            }
            output.append(mono(text, outputColor))
        }
        switch ToolPresentation.detail(tool) {
        case .command(let command, let result):
            output.append(mono("$ ", .tertiaryLabelColor))
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
            if let scope { output.append(mono("  in " + scope, .tertiaryLabelColor)) }
            appendOutput(result)
        case .fields(let fields, let result):
            for (index, field) in fields.enumerated() {
                if index > 0 { output.append(mono("\n", .labelColor)) }
                output.append(mono(field.key + "  ", .tertiaryLabelColor))
                output.append(mono(field.value, .labelColor))
            }
            appendOutput(result)
        }
        if tool.result?.truncated == true {
            output.append(mono("\n", .labelColor))
            output.append(gap(6))
            output.append(NSAttributedString(string: "Output shortened", attributes: Theme.text(Theme.smallFont, color: .tertiaryLabelColor, line: 17)))
        } else if !hasOutput {
            if output.length > 0 { output.append(mono("\n", .labelColor)) }
            output.append(mono(tool.isFinished ? "No output" : "Running…", .tertiaryLabelColor))
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
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style, .baselineOffset: offset]
        let textAttributes: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style, .baselineOffset: offset]
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: textAttributes)) }
            output.append(NSAttributedString(string: "\t" + (line.number.map(String.init) ?? "") + "\t", attributes: numberAttributes))
            output.append(NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: textAttributes))
        }
        return output
    }

    // MARK: Diffs

    /// A diff and, if it was cut short, a quiet note of how much was left out.
    static func diffWithNote(_ diffs: [EditDiff], maxLines: Int, inset: CGFloat = 10) -> NSAttributedString {
        let (diff, hidden) = diffText(diffs, maxLines: maxLines, inset: inset)
        guard hidden > 0 else { return diff }
        let body = NSMutableAttributedString(attributedString: diff)
        let (style, offset) = Theme.lines(24, font: Theme.smallFont, head: inset, first: inset)
        let note: [NSAttributedString.Key: Any] = [.font: Theme.smallFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style, .baselineOffset: offset]
        body.append(NSAttributedString(string: "\n", attributes: note))
        body.append(NSAttributedString(string: hidden == 1 ? "1 more line not shown" : "\(hidden) more lines not shown", attributes: note))
        return body
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
        let (style, offset) = Theme.lines(Theme.diffLine, font: Theme.diffFont, head: textAt, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .right, location: numberEnd), NSTextTab(textAlignment: .left, location: signAt),
                          NSTextTab(textAlignment: .left, location: textAt)]
        style.lineBreakMode = .byCharWrapping
        let gutter: [NSAttributedString.Key: Any] = [.font: Theme.diffFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style, .baselineOffset: offset]
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
        let title = NSAttributedString(string: card.title, attributes: [.font: NSFont.systemFont(ofSize: TypeScale.cardTitle, weight: .medium), .foregroundColor: NSColor.labelColor])
        let total = statsText(added: card.added, removed: card.removed)
        var parts: [RowRender.Part] = []
        var height = RowMetrics.changesHeader
        for file in card.files {
            let line = NSMutableAttributedString(string: file.name, attributes: [.font: Theme.workFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
            if !file.folder.isEmpty {
                line.append(NSAttributedString(string: "  " + file.folder, attributes: [.font: Theme.detailFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: truncating]))
            }
            var part = RowRender.Part(leading: line, trailing: statsText(added: file.added, removed: file.removed))
            height += RowMetrics.changesFile
            if file.isExpanded {
                let body = diffWithNote(file.diffs, maxLines: 600, inset: RowMetrics.cardPad)
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

    static func approvalTitle(_ request: ApprovalRequest) -> String {
        let path = request.input["file_path"]?.stringValue ?? request.input["path"]?.stringValue
        let file = path.map { ($0 as NSString).lastPathComponent }
        switch request.name {
        case "Bash": return "Run this command?"
        case "Edit", "MultiEdit", "NotebookEdit": return file.map { "Edit \($0)?" } ?? "Edit this file?"
        case "Write": return file.map { "Write \($0)?" } ?? "Write this file?"
        case "WebFetch": return "Fetch this page?"
        case "WebSearch": return "Search the web?"
        default:
            let parts = request.name.split(separator: "_", omittingEmptySubsequences: true)
            let name = request.name.hasPrefix("mcp__") && parts.count >= 3 ? parts.dropFirst(2).joined(separator: " ") : request.name
            return "Use \(name)?"
        }
    }

    /// The command, or the file and the start of what would be written, in
    /// a monospaced block.
    static func approvalPayload(_ request: ApprovalRequest) -> NSAttributedString {
        let input = request.input
        if let command = input["command"]?.stringValue {
            return mono(clampLines(command, 12), .labelColor)
        }
        let output = NSMutableAttributedString()
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
            output.append(mono(ToolPresentation.shortTitle(path, limit: 300), .secondaryLabelColor))
            let call = ToolCall(itemId: request.approvalId, name: request.name, kind: request.name == "Write" ? .write : .edit,
                                title: request.title, input: input)
            if let diff = DiffBuilder.diff(forTool: call), !diff.hunks.isEmpty {
                output.append(mono("\n", .labelColor))
                output.append(gap(6))
                output.append(diffText([diff], maxLines: 8, inset: 0).0)
            }
            return output
        }
        if let url = input["url"]?.stringValue {
            return mono(url, .labelColor)
        }
        let fields = ToolPresentation.fields(input)
        if fields.isEmpty { return mono(clampLines(request.title, 10), .labelColor) }
        for (index, field) in fields.prefix(8).enumerated() {
            if index > 0 { output.append(mono("\n", .labelColor)) }
            output.append(mono(field.key + "  ", .tertiaryLabelColor))
            output.append(mono(field.value, .labelColor))
        }
        return output
    }

    static func questionText(_ question: String) -> NSAttributedString {
        NSAttributedString(string: question, attributes: Theme.text(Theme.cardTitleFont, line: 20))
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

    static func planText(_ entries: [PlanEntry]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: TypeScale.body - 0.5)
        let (style, offset) = Theme.lines(22, font: font, spacing: 4, head: 24, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        for (index, entry) in entries.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style, .baselineOffset: offset])) }
            let (mark, color, textColor): (String, NSColor, NSColor) = switch entry.status {
            case .completed: ("✓", Theme.addedText, .secondaryLabelColor)
            case .in_progress: ("●", .controlAccentColor, .labelColor)
            case .pending: ("○", .tertiaryLabelColor, .labelColor)
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
            .foregroundColor: completion.outcome == .failed ? NSColor.systemRed : NSColor.tertiaryLabelColor,
            .paragraphStyle: truncating,
        ])
    }

    // MARK: Images

    /// Lays images out in rows, each scaled to fit `maxHeight` and `maxWidth`.
    static func imageFrames(_ images: [ImageRef], maxWidth: CGFloat, maxHeight: CGFloat, alignRight: Bool) -> ([NSRect], CGFloat) {
        guard !images.isEmpty else { return ([], 0) }
        var frames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0
        let cellMaxWidth = min(maxWidth, RowMetrics.gridMaxWidth)
        func finishRow() {
            guard alignRight, rowStart < frames.count else { return }
            let used = frames[frames.count - 1].maxX
            let shift = maxWidth - used
            for index in rowStart..<frames.count { frames[index].origin.x += shift }
        }
        for image in images {
            let size = pixelSize(image)
            let scale = min(1, maxHeight / max(1, size.height), cellMaxWidth / max(1, size.width))
            let width = max(24, floor(size.width * scale))
            let height = max(24, floor(size.height * scale))
            if x > 0, x + width > maxWidth {
                finishRow()
                y += rowHeight + RowMetrics.imageGap
                x = 0
                rowHeight = 0
                rowStart = frames.count
            }
            frames.append(NSRect(x: x, y: y, width: width, height: height))
            x += width + RowMetrics.imageGap
            rowHeight = max(rowHeight, height)
        }
        finishRow()
        return (frames, y + rowHeight)
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
