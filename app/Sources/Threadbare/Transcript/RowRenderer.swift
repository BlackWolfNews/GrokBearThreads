import AppKit
import Synchronization
import ThreadbareCore

/// Layout numbers shared by height measurement and the cell views, so the
/// two always agree.
enum RowMetrics {
    static let rowTop: CGFloat = 6
    static let rowBottom: CGFloat = 6
    static let headerHeight: CGFloat = 26
    static let bubblePadH: CGFloat = 13
    static let bubblePadV: CGFloat = 8
    static let boxPad: CGFloat = 10
    static let diffPad: CGFloat = 6
    static let bodyIndent: CGFloat = 20
    static let cardPad: CGFloat = 12
    static let buttonHeight: CGFloat = 28
    static let optionHeight: CGFloat = 22
    static let optionDescription: CGFloat = 16
    static let userThumbHeight: CGFloat = 96
    static let gridMaxHeight: CGFloat = 220
    static let gridMaxWidth: CGFloat = 340
    static let imageGap: CGFloat = 8
    static let collapsedDiffLines = 14
    static let footerHeight: CGFloat = 28

    /// The reading column for a given table width: (x, width).
    static func column(tableWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = max(200, min(tableWidth - Theme.sideInset * 2, Theme.maxContentWidth))
        return (floor((tableWidth - width) / 2), floor(width))
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

    init(height: CGFloat, text: NSAttributedString? = nil, textSize: NSSize = .zero, detail: NSAttributedString? = nil, detailSize: NSSize = .zero,
         blocks: [String] = [], blockStarts: [Int] = [], imageFrames: [NSRect] = [], imageAreaHeight: CGFloat = 0, lineHeights: [CGFloat] = []) {
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
    }
}

/// Caches renders by (row id, content version, expanded, width).
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
        let characters = (render.text?.length ?? 0) + (render.detail?.length ?? 0)
        return 512 + characters * 12 + render.blocks.reduce(0) { $0 + $1.utf8.count }
    }

    /// Keyed by the reading column's width, which is all a render depends
    /// on: tables of different widths with the column at its widest share
    /// renders, so a sidebar drag or a scroller appearing costs nothing.
    static func key(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> NSString {
        "\(row.id)|\(row.version)|\(expanded ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))" as NSString
    }

    func cached(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> RowRender? {
        cache.object(forKey: Self.key(row, expanded: expanded, width: width))
    }

    func render(_ row: TranscriptRow, expanded: Bool, width: CGFloat) -> RowRender {
        let key = Self.key(row, expanded: expanded, width: width)
        if let hit = cache.object(forKey: key) { return hit }
        let render = RowRenderer.render(row, expanded: expanded, tableWidth: width, measurer: .current)
        store(render, key: key, row: row, expanded: expanded, width: width)
        return render
    }

    func store(_ render: RowRender, for row: TranscriptRow, expanded: Bool, width: CGFloat) {
        store(render, key: Self.key(row, expanded: expanded, width: width), row: row, expanded: expanded, width: width)
    }

    private func store(_ render: RowRender, key: NSString, row: TranscriptRow, expanded: Bool, width: CGFloat) {
        cache.setObject(render, forKey: key, cost: Self.cost(render))
        let slot = "\(row.id)|\(expanded ? 1 : 0)|\(Int(RowMetrics.column(tableWidth: width).width))"
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
    /// Still changing: streaming text or a tool that hasn't finished.
    var isLive: Bool {
        switch content {
        case .assistant(let item), .reasoning(let item): return item.isStreaming
        case .tool(let tool): return !tool.isFinished
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
        let width = RowMetrics.column(tableWidth: tableWidth).width
        let vertical = RowMetrics.rowTop + RowMetrics.rowBottom
        switch row.content {
        case .user(let message):
            let maxText = floor(width * 0.84) - RowMetrics.bubblePadH * 2
            let text = plainText(message.text.isEmpty ? " " : message.text, font: Theme.bodyFont, color: .labelColor)
            let size = measurer.measure(text, width: maxText)
            let (frames, area) = imageFrames(message.images, maxWidth: width, maxHeight: RowMetrics.userThumbHeight, alignRight: true)
            let imageBlock = message.images.isEmpty ? 0 : RowMetrics.imageGap + area
            let showText = !message.text.isEmpty || message.images.isEmpty
            let bubble = showText ? size.height + RowMetrics.bubblePadV * 2 : 0
            return RowRender(height: vertical + 6 + bubble + imageBlock, text: showText ? text : nil, textSize: size, imageFrames: frames, imageAreaHeight: area)

        case .assistant(let item):
            let rendered = MarkdownRenderer.render(item.text)
            // While a reply streams, each flush measures only what changed
            // since the last one (the finished blocks keep their layout).
            // Measuring the whole message every flush was 61% of the main
            // thread in a long pinned stream, growing with the message.
            let size = item.isStreaming && Thread.isMainThread
                ? StreamingMeasurer.main.measure(rowId: row.id, rendered, width: width)
                : measurer.measure(rendered.string, width: width)
            // Only a streaming row needs its blocks (for in-place updates);
            // a finished one would just hold a second copy of its markdown.
            return RowRender(height: vertical + size.height + 2, text: rendered.string, textSize: size,
                             blocks: item.isStreaming ? rendered.blocks : [], blockStarts: item.isStreaming ? rendered.starts : [])

        case .reasoning(let item):
            let header = headerText(title: item.isStreaming ? "Thinking…" : "Thinking", subtitle: firstLine(item.text), secondary: true)
            guard expanded else { return RowRender(height: RowMetrics.headerHeight, text: header) }
            let body = plainText(item.text, font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
            let size = measurer.measure(body, width: width - RowMetrics.bodyIndent)
            return RowRender(height: RowMetrics.headerHeight + size.height + 10, text: header, detail: body, detailSize: size)

        case .tool(let tool):
            let header = toolHeader(tool)
            if row.kind == .diff, let diff = tool.effectiveDiff, !diff.hunks.isEmpty {
                let body = diffText(diff, maxLines: expanded ? 1500 : RowMetrics.collapsedDiffLines)
                let size = measurer.measure(body, width: width - RowMetrics.diffPad * 2)
                return RowRender(height: RowMetrics.headerHeight + size.height + RowMetrics.diffPad * 2 + 8, text: header, detail: body, detailSize: size)
            }
            guard expanded else { return RowRender(height: RowMetrics.headerHeight, text: header) }
            let body = toolBody(tool)
            let size = measurer.measure(body, width: width - RowMetrics.bodyIndent - RowMetrics.boxPad * 2)
            return RowRender(height: RowMetrics.headerHeight + size.height + RowMetrics.boxPad * 2 + 8, text: header, detail: body, detailSize: size)

        case .images(_, let images):
            let (frames, area) = imageFrames(images, maxWidth: width - RowMetrics.bodyIndent, maxHeight: RowMetrics.gridMaxHeight, alignRight: false)
            return RowRender(height: vertical + area, imageFrames: frames, imageAreaHeight: area)

        case .approval(let item):
            let inner = width - RowMetrics.cardPad * 2
            let title = plainText(approvalTitle(item.request), font: Theme.boldFont, color: .labelColor)
            let titleSize = measurer.measure(title, width: inner)
            let detail = plainText(clampLines(item.request.title, 10), font: Theme.codeFont, color: .secondaryLabelColor)
            let detailSize = measurer.measure(detail, width: inner)
            let height = vertical + RowMetrics.cardPad * 2 + titleSize.height + 6 + detailSize.height + 10 + RowMetrics.buttonHeight
            return RowRender(height: height, text: title, textSize: titleSize, detail: detail, detailSize: detailSize)

        case .question(let item):
            let inner = width - RowMetrics.cardPad * 2
            var total = RowMetrics.cardPad * 2
            var textHeights: [CGFloat] = []
            for question in item.request.questions {
                let textHeight = measurer.measure(questionText(question.question), width: inner).height
                textHeights.append(textHeight)
                total += questionHeight(question, textHeight: textHeight)
            }
            total += item.resolution == nil ? (26 + 8 + RowMetrics.buttonHeight) : 20
            return RowRender(height: vertical + total, lineHeights: textHeights)

        case .plan(let entries):
            let text = planText(entries)
            let size = measurer.measure(text, width: width - RowMetrics.cardPad * 2)
            return RowRender(height: vertical + size.height + RowMetrics.cardPad * 2, text: text, textSize: size)

        case .footer(let completion):
            return RowRender(height: RowMetrics.footerHeight, text: footerText(completion))

        case .note(let note):
            let text = plainText(note, font: Theme.smallFont, color: .secondaryLabelColor, alignment: .center)
            let size = measurer.measure(text, width: width)
            return RowRender(height: vertical + size.height, text: text, textSize: size)

        case .error(let message):
            let text = plainText(message, font: Theme.bodyFont, color: .systemRed)
            let size = measurer.measure(text, width: width - RowMetrics.boxPad * 2)
            return RowRender(height: vertical + size.height + RowMetrics.boxPad * 2, text: text, textSize: size)
        }
    }

    // MARK: Pieces

    static func plainText(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let style = Theme.paragraph(spacing: 4)
        style.alignment = alignment
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 200 ? String(line.prefix(200)) : line
    }

    static func clampLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > count else { return text }
        return lines.prefix(count).joined(separator: "\n") + "\n…"
    }

    static func headerText(title: String, subtitle: String, secondary: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let output = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
        if !subtitle.isEmpty {
            output.append(NSAttributedString(string: "  " + subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
            ]))
        }
        return output
    }

    static func toolHeader(_ tool: ToolItem) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let title = ToolPresentation.shortTitle(tool.title)
        let output = NSMutableAttributedString(string: title, attributes: [
            .font: Theme.toolFont, .foregroundColor: tool.failed ? NSColor.systemRed : NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
        if let diff = tool.effectiveDiff, !diff.hunks.isEmpty {
            let stats = DiffBuilder.stats(diff)
            output.append(NSAttributedString(string: "  +\(stats.added)", attributes: [.font: Theme.toolFont, .foregroundColor: NSColor.systemGreen, .paragraphStyle: style]))
            output.append(NSAttributedString(string: " −\(stats.removed)", attributes: [.font: Theme.toolFont, .foregroundColor: NSColor.systemRed, .paragraphStyle: style]))
        }
        return output
    }

    static func toolBody(_ tool: ToolItem) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let style = Theme.paragraph(lineHeight: 1.12, spacing: 0)
        style.lineBreakMode = .byCharWrapping
        let inputText: String
        if let command = tool.call?.input["command"]?.stringValue {
            inputText = "$ " + command
        } else if let call = tool.call {
            inputText = clampLines(call.input.prettyText, 40)
        } else {
            inputText = ""
        }
        if !inputText.isEmpty {
            output.append(NSAttributedString(string: inputText, attributes: [.font: Theme.codeBoldFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        }
        let result = ToolPresentation.outputPreview(tool)
        if !result.isEmpty {
            if output.length > 0 { output.append(NSAttributedString(string: "\n\n", attributes: [.font: Theme.codeFont, .paragraphStyle: style])) }
            let color: NSColor = tool.failed ? .systemRed : .secondaryLabelColor
            output.append(NSAttributedString(string: result.trimmingCharacters(in: .newlines), attributes: [.font: Theme.codeFont, .foregroundColor: color, .paragraphStyle: style]))
        }
        if tool.result?.truncated == true {
            output.append(NSAttributedString(string: "\n(output shortened)", attributes: [.font: Theme.smallFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]))
        }
        if output.length == 0 {
            output.append(NSAttributedString(string: tool.isFinished ? "(no output)" : "Running…", attributes: [.font: Theme.codeFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]))
        }
        return output
    }

    static func diffText(_ diff: EditDiff, maxLines: Int) -> NSAttributedString {
        let lines = DiffBuilder.displayLines(diff, maxLines: maxLines)
        let output = NSMutableAttributedString()
        let style = Theme.paragraph(lineHeight: 1.1, spacing: 0)
        style.lineBreakMode = .byCharWrapping
        style.headIndent = 0
        let gutter = NSColor.tertiaryLabelColor
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: Theme.codeFont, .paragraphStyle: style])) }
            let start = output.length
            let number: String
            let sign: String
            let background: NSColor?
            var color = NSColor.labelColor
            switch line.kind {
            case .added: number = line.newNumber.map(String.init) ?? ""; sign = "+"; background = Theme.addedBackground
            case .removed: number = line.oldNumber.map(String.init) ?? ""; sign = "-"; background = Theme.removedBackground
            case .context: number = line.newNumber.map(String.init) ?? ""; sign = " "; background = nil
            case .hunkHeader: number = ""; sign = ""; background = Theme.hunkBackground; color = .secondaryLabelColor
            case .elided: number = ""; sign = ""; background = nil; color = .tertiaryLabelColor
            }
            let padded = String(repeating: " ", count: max(0, 4 - number.count)) + number
            if line.kind == .elided {
                output.append(NSAttributedString(string: "      " + line.text, attributes: [.font: Theme.smallFont, .foregroundColor: color, .paragraphStyle: style]))
            } else {
                output.append(NSAttributedString(string: padded + " ", attributes: [.font: Theme.codeFont, .foregroundColor: gutter, .paragraphStyle: style]))
                output.append(NSAttributedString(string: sign + " " + line.text.replacingOccurrences(of: "\t", with: "    "), attributes: [.font: Theme.codeFont, .foregroundColor: color, .paragraphStyle: style]))
            }
            if let background {
                output.addAttribute(.tbLineBackground, value: background, range: NSRange(location: start, length: output.length - start))
            }
        }
        return output
    }

    static func approvalTitle(_ request: ApprovalRequest) -> String {
        switch request.name {
        case "Bash": return "Claude wants to run a command"
        case "Edit", "MultiEdit": return "Claude wants to edit a file"
        case "Write": return "Claude wants to write a file"
        case "WebFetch": return "Claude wants to fetch a page"
        default: return "Claude wants to use \(request.name)"
        }
    }

    static func questionText(_ question: String) -> NSAttributedString {
        plainText(question, font: Theme.boldFont, color: .labelColor)
    }

    static func questionHeight(_ question: Question, textHeight: CGFloat) -> CGFloat {
        // The question's short `header` isn't shown: it would read as an eyebrow label.
        var height: CGFloat = textHeight + 6
        for option in question.options {
            height += RowMetrics.optionHeight
            if let description = option.description, !description.isEmpty { height += RowMetrics.optionDescription }
        }
        return height + 10
    }

    static func planText(_ entries: [PlanEntry]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let style = Theme.paragraph(spacing: 3, head: 20, first: 0)
        style.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
        for (index, entry) in entries.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: Theme.bodyFont, .paragraphStyle: style])) }
            let (mark, color, textColor): (String, NSColor, NSColor) = switch entry.status {
            case .completed: ("✓", .systemGreen, .secondaryLabelColor)
            case .in_progress: ("●", .controlAccentColor, .labelColor)
            case .pending: ("○", .tertiaryLabelColor, .labelColor)
            }
            output.append(NSAttributedString(string: mark + "\t", attributes: [.font: Theme.bodyFont, .foregroundColor: color, .paragraphStyle: style]))
            var attributes: [NSAttributedString.Key: Any] = [.font: Theme.bodyFont, .foregroundColor: textColor, .paragraphStyle: style]
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
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: Theme.smallFont,
            .foregroundColor: completion.outcome == .failed ? NSColor.systemRed : NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ])
    }

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
