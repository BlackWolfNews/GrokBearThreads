import AppKit
import Markdown
import ThreadbearCore

/// Renders markdown into an `NSAttributedString` for TextKit 1 text views.
/// Text is split into top-level blocks (`MarkdownBlocks`) and each block is
/// rendered once and cached by its text, so a streaming message only
/// re-renders its last, still-open block. Safe to call off the main thread.
enum MarkdownRenderer {
    /// A bare absolute path parses as a URL without a scheme, which looks
    /// clickable but cannot be opened. Give the transcript's file opener a
    /// file URL, keeping URL escaping and HTML fragments intact.
    private static func linkURL(_ destination: String) -> URL? {
        // end_turn's links take ~ paths, so an ask's words linked to the
        // same place (needs.ts) may well use one too.
        if destination.hasPrefix("~/") {
            let path = destination.removingPercentEncoding ?? destination
            let whole = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // `~/a/grow.html?clean`: the file, and the query for its page,
            // unless the whole thing is a file's name.
            let parts = FilePathRefs.splitQuery(destination)
            guard parts.query != nil || parts.fragment != nil, !FileManager.default.fileExists(atPath: whole.path) else { return whole }
            let file = URL(fileURLWithPath: ((parts.path.removingPercentEncoding ?? parts.path) as NSString).expandingTildeInPath)
            return FilePathRefs.withQuery(file, query: parts.query, fragment: parts.fragment)
        }
        // A relative target (`[plan](shorts-plan/candidates.md)`) means a
        // file from the thread's folder, so it's found the way a path in
        // inline code is (FilePathRefs). Left as a scheme-less URL, AppKit
        // hands it to NSWorkspace and Finder says "can't be opened. -50".
        // A lone `#section` has nowhere to go in a transcript.
        if !destination.hasPrefix("/"), destination.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil {
            guard !destination.hasPrefix("#") else { return nil }
            return FilePathRefs.url(for: destination.removingPercentEncoding ?? destination)
        }
        guard var components = URLComponents(string: destination) else { return nil }
        if components.scheme == nil, destination.hasPrefix("/") {
            components.scheme = "file"
            components.host = ""
        }
        return components.url
    }

    nonisolated(unsafe) static let urlDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    struct Rendered {
        let string: NSAttributedString
        let blocks: [String]
        /// UTF-16 offset where each block starts in `string`.
        let starts: [Int]
        /// Room a code block's box needs below the last line when the
        /// message ends with one (paragraph spacing after the last paragraph
        /// doesn't count in TextKit's height).
        var trailingPad: CGFloat = 0
    }

    /// How far a code block's box reaches past its text.
    static var codePad: CGFloat { zoomed(12) }
    /// How far an inline code pill reaches past its glyphs on each side,
    /// and the space kerned in either side of the run to make room for it.
    static var pillPad: CGFloat { zoomed(2.5) }
    static var pillKern: CGFloat { zoomed(4) }

    nonisolated(unsafe) private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        // Mostly for streaming (finished blocks of the open message) and
        // re-rendering at a new width; finished rows live in RenderCache.
        cache.countLimit = 1500
        cache.totalCostLimit = 2_000_000 // UTF-16 code units
        return cache
    }()

    static func render(_ text: String) -> Rendered {
        let blocks = MarkdownBlocks.split(text)
        let output = NSMutableAttributedString()
        var starts: [Int] = []
        starts.reserveCapacity(blocks.count)
        // TextKit ignores spacing before the first paragraph, so a message
        // that opens with a code block gets a tiny spacer line for its box's
        // top padding to sit in. The first block's kind never changes as a
        // message streams, so block offsets stay stable.
        if let first = blocks.first, isCodeBlock(first) { output.append(leadingSpacer) }
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(separator) }
            starts.append(output.length)
            output.append(renderBlock(block))
        }
        let pad = blocks.last.map(isCodeBlock) == true ? codePad : 0
        return Rendered(string: output, blocks: blocks, starts: starts, trailingPad: pad)
    }

    static func isCodeBlock(_ block: String) -> Bool {
        let trimmed = block.drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static let leadingSpacer: NSAttributedString = {
        let (style, _) = Theme.lines(1, font: .systemFont(ofSize: 1))
        return NSAttributedString(string: "\u{200B}\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style])
    }()

    static func renderBlock(_ block: String) -> NSAttributedString {
        // The zoom is in the key: a block's layout is all sizes.
        let key = "\(TypeScale.percent)|\(block)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        // `[tests pass](work:npm test)`: a space ends a link's destination
        // for the parser, so work: and thread: links are escaped first.
        let document = Document(parsing: WorkLinks.escapeDestinations(block), options: [.disableSmartOpts])
        var builder = Builder()
        for child in document.children {
            builder.block(child, Context())
        }
        builder.trimTrailingNewline()
        builder.linkBareURLs()
        builder.freeLinesWithPictures()
        let result = NSAttributedString(attributedString: builder.output)
        cache.setObject(result, forKey: key, cost: block.utf16.count)
        return result
    }

    /// How big an inline picture is drawn at most, in points before zoom.
    static var pictureMaxWidth: CGFloat { zoomed(420) }
    static var pictureMaxHeight: CGFloat { zoomed(320) }

    /// A picture the agent wrote as `![alt](/path/to/file.png)`, drawn at
    /// most pictureMaxWidth by pictureMaxHeight. Nil for a file that isn't
    /// there or isn't a picture. Decoded here, off the main thread, at the
    /// size it's drawn (twice, for Retina); the block's cache keeps it.
    static func picture(path: String, alt: String) -> NSTextAttachment? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let scale: CGFloat = 2
        guard let image = ThumbnailLoader.decode(path: path, maxPixels: Int(max(pictureMaxWidth, pictureMaxHeight) * scale)) else { return nil }
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, pictureMaxWidth / max(size.width, 1), pictureMaxHeight / max(size.height, 1))
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let attachment = NSTextAttachment()
        attachment.image = NSImage(cgImage: image, size: size)
        attachment.bounds = CGRect(origin: .zero, size: size)
        return attachment
    }

    private static var separator: NSAttributedString { NSAttributedString(string: "\n", attributes: Theme.bodyAttributes) }

    struct Context {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL?
        var color: NSColor = .labelColor
        var indent: CGFloat = 0
        var headingLevel = 0
        var listSpacing: CGFloat?
    }

    struct Builder {
        let output = NSMutableAttributedString()

        /// Body lines have a fixed height, which would cut a picture down to
        /// one line: a paragraph with one gets a style that lets it grow,
        /// and the picture sits on the baseline.
        mutating func freeLinesWithPictures() {
            let text = output.string as NSString
            output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, range, _ in
                guard value is NSTextAttachment else { return }
                let paragraph = text.paragraphRange(for: range)
                let old = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
                let style = (old.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.minimumLineHeight = 0
                style.maximumLineHeight = 0
                output.addAttribute(.paragraphStyle, value: style, range: paragraph)
                output.addAttribute(.baselineOffset, value: 0, range: range)
            }
        }

        mutating func trimTrailingNewline() {
            while output.length > 0, output.string.utf16.last == 10 {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        func font(_ context: Context) -> NSFont {
            if context.code { return context.bold ? Theme.codeBoldFont : Theme.codeFont }
            var font: NSFont
            switch context.headingLevel {
            case 1...3: font = Self.headingFont(context.headingLevel)
            case 4...: font = Theme.boldFont
            default: font = context.bold ? Theme.boldFont : Theme.bodyFont
            }
            if context.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }

        func attributes(_ context: Context) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [.font: font(context), .foregroundColor: context.color]
            // Drawn by BackgroundLayoutManager as a rounded pill with a little
            // padding, which `.backgroundColor` (a tight glyph box) can't do.
            if context.code && context.headingLevel == 0 { attributes[.tbInlineBackground] = Theme.inlineCodeBackground }
            if context.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = context.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                // Otherwise the tip is the raw link, `tbpath:?p=…` for a path.
                if link.isFileURL || FilePathRefs.text(of: link) != nil {
                    attributes[.toolTip] = "Click to open, right-click for more"
                }
            }
            return attributes
        }

        func append(_ text: String, _ context: Context) {
            output.append(NSAttributedString(string: text, attributes: attributes(context)))
        }

        /// Gap after a paragraph, and between list items.
        static var paragraphGap: CGFloat { zoomed(10) }
        static var itemGap: CGFloat { zoomed(6) }

        func paragraphStyle(_ context: Context, spacing: CGFloat? = nil, before: CGFloat = 0, first: CGFloat? = nil, tabs: [CGFloat] = [],
                            line: CGFloat = Theme.bodyLine, font: NSFont = Theme.bodyFont) -> (style: NSParagraphStyle, offset: CGFloat) {
            let (style, offset) = Theme.lines(line, font: font, spacing: spacing ?? context.listSpacing ?? Self.paragraphGap,
                                              before: before, head: context.indent, first: first)
            if !tabs.isEmpty {
                style.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
                style.defaultTabInterval = zoomed(28)
            }
            return (style, offset)
        }

        mutating func finishParagraph(from start: Int, style: (style: NSParagraphStyle, offset: CGFloat)) {
            append("\n", Context())
            let range = NSRange(location: start, length: output.length - start)
            output.addAttribute(.paragraphStyle, value: style.style, range: range)
            // One offset for the whole line, so smaller runs (inline code)
            // share the body text's baseline.
            output.addAttribute(.baselineOffset, value: style.offset, range: range)
        }

        /// swift-markdown leaves a bare URL like http://localhost:5176 as
        /// plain text (it doesn't run GFM's autolink extension), and agents
        /// write them that way all the time. Done over the whole block, not
        /// per Text node, because cmark splits text at characters like `_`.
        /// Only http(s) with the scheme written out: the detector also
        /// guesses at words like CLAUDE.md, which aren't links. Code blocks
        /// stay as they are; inline code that's a URL gets linked.
        mutating func linkBareURLs() {
            let text = output.string
            guard text.contains("://") else { return }
            for match in MarkdownRenderer.urlDetector.matches(in: text, range: NSRange(location: 0, length: output.length)) {
                let range = match.range
                let word = output.mutableString.substring(with: range).lowercased()
                guard word.hasPrefix("http://") || word.hasPrefix("https://"), let url = match.url else { continue }
                var taken = false
                output.enumerateAttributes(in: range) { attributes, _, stop in
                    if attributes[.link] != nil || attributes[.tbBlockBackground] != nil { taken = true; stop.pointee = true }
                }
                guard !taken else { continue }
                output.addAttribute(.link, value: url, range: range)
                output.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
                // A link keeps its own destination, not a thread chip.
                output.removeAttribute(.tbThreadRef, range: range)
            }
        }

        // MARK: Blocks

        mutating func block(_ markup: Markup, _ context: Context, listPrefix: String? = nil) {
            switch markup {
            case let paragraph as Paragraph:
                let start = output.length
                var first: CGFloat?
                var tabs: [CGFloat] = []
                if let listPrefix {
                    appendMarker(listPrefix, context)
                    first = Self.markerStart(listPrefix, indent: context.indent)
                    tabs = [context.indent]
                }
                inlines(paragraph.children, context)
                finishParagraph(from: start, style: paragraphStyle(context, first: first, tabs: tabs))

            case let heading as Heading:
                var inner = context
                inner.headingLevel = heading.level
                let start = output.length
                inlines(heading.children, inner)
                // 16 above in all (the paragraph before leaves 10), 6 below.
                let font = Self.headingFont(heading.level)
                finishParagraph(from: start, style: paragraphStyle(context, spacing: zoomed(6), before: zoomed(6), line: ceil(font.pointSize * 1.4), font: font))

            case let code as CodeBlock:
                codeBlock(code.code, context)

            case let quote as BlockQuote:
                var inner = context
                inner.indent += zoomed(14)
                inner.color = .secondaryLabelColor
                for child in quote.children { block(child, inner) }

            case let list as UnorderedList:
                listItems(Array(list.listItems), context) { _, item in
                    switch item.checkbox {
                    case .checked?: return "☑"
                    case .unchecked?: return "☐"
                    case nil: return "•"
                    }
                }

            case let list as OrderedList:
                let startIndex = Int(list.startIndex)
                listItems(Array(list.listItems), context) { index, _ in "\(startIndex + index)." }

            case is ThematicBreak:
                let start = output.length
                var inner = context
                inner.color = .tertiaryLabelColor
                append(String(repeating: "─", count: 24), inner)
                finishParagraph(from: start, style: paragraphStyle(context))

            case let table as Markdown.Table:
                renderTable(table, context)

            case let html as HTMLBlock:
                var inner = context
                inner.color = .secondaryLabelColor
                inner.code = true
                let start = output.length
                append(html.rawHTML.trimmingCharacters(in: .newlines), inner)
                finishParagraph(from: start, style: paragraphStyle(context))

            default:
                if markup.childCount > 0, markup is BlockContainer {
                    for child in markup.children { block(child, context) }
                } else {
                    let start = output.length
                    append(markup.format().trimmingCharacters(in: .newlines), context)
                    finishParagraph(from: start, style: paragraphStyle(context))
                }
            }
        }

        static func headingFont(_ level: Int) -> NSFont {
            switch level {
            case 1: return .systemFont(ofSize: TypeScale.headings.0, weight: .semibold)
            case 2: return .systemFont(ofSize: TypeScale.headings.1, weight: .semibold)
            default: return .systemFont(ofSize: TypeScale.headings.2, weight: .semibold)
            }
        }

        /// How far a list's text sits in from its parent's. At 22, with the
        /// marker 2 pt from the column edge, lists looked cramped against
        /// the paragraphs around them; Claude's sit clearly in.
        static var listIndent: CGFloat { zoomed(30) }

        /// Where an item's marker starts: a bullet 18 pt before the text, a
        /// number a little further out so "10." still fits before it.
        static func markerStart(_ marker: String, indent: CGFloat) -> CGFloat {
            max(0, indent - zoomed(marker == "•" ? 18 : 22))
        }

        /// A list marker and the tab to the item's text. The bullet is drawn
        /// semibold: at the body weight it read small beside 15 pt text.
        func appendMarker(_ marker: String, _ context: Context) {
            var markerContext = context
            markerContext.link = nil
            markerContext.strike = false
            if marker == "•" { markerContext.bold = true }
            append(marker, markerContext)
            append("\t", context)
        }

        mutating func listItems(_ items: [ListItem], _ context: Context, marker: (Int, ListItem) -> String) {
            var inner = context
            inner.indent += Self.listIndent
            for (index, item) in items.enumerated() {
                var itemContext = inner
                itemContext.listSpacing = index == items.count - 1 && context.listSpacing == nil ? Self.paragraphGap : Self.itemGap
                var first = true
                for child in item.children {
                    if first, child is Paragraph {
                        block(child, itemContext, listPrefix: marker(index, item))
                    } else {
                        if first {
                            // A list item that starts with something other than text still gets its marker.
                            let start = output.length
                            let mark = marker(index, item)
                            append(mark, itemContext)
                            finishParagraph(from: start, style: paragraphStyle(itemContext, spacing: zoomed(2), first: Self.markerStart(mark, indent: itemContext.indent)))
                        }
                        block(child, itemContext)
                    }
                    first = false
                }
            }
        }

        mutating func codeBlock(_ code: String, _ context: Context) {
            var text = code
            while text.hasSuffix("\n") { text.removeLast() }
            if text.isEmpty { text = " " }
            // U+2028 keeps the block one paragraph, so spacing before and
            // after applies once around the whole box. The box reaches
            // `codePad` past the text on every side (BackgroundLayoutManager),
            // so the spacing leaves the usual paragraph gap outside it.
            let body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
            let pad = MarkdownRenderer.codePad
            let (style, offset) = Theme.lines(Theme.codeLine, font: Theme.codeFont, spacing: Self.paragraphGap + pad, before: pad,
                                              head: context.indent + pad, tail: -pad)
            style.lineBreakMode = .byCharWrapping
            let start = output.length
            output.append(NSAttributedString(string: body, attributes: [
                .font: Theme.codeFont,
                .foregroundColor: NSColor.labelColor,
                .tbBlockBackground: Theme.codeBackground,
            ]))
            append("\n", Context())
            let range = NSRange(location: start, length: output.length - start)
            output.addAttribute(.paragraphStyle, value: style, range: range)
            output.addAttribute(.baselineOffset, value: offset, range: range)
        }

        /// Space either side of a column boundary, and above and below a
        /// row's text (its rule sits in the middle of the gap).
        static var cellPadH: CGFloat { zoomed(12) }
        static var cellPadV: CGFloat { zoomed(4) }

        /// A grid like the references draw: a rule under the header and
        /// hairlines between rows. Each cell is its own paragraph in an
        /// NSTextTable, so a long cell wraps inside its own column (tab stops
        /// wrapped it back under the first one, and a cell wider than its
        /// stop pushed the rest of the row along).
        mutating func renderTable(_ table: Markdown.Table, _ context: Context) {
            var rows: [[NSAttributedString]] = []
            func cells(_ cells: some Sequence<Markdown.Table.Cell>, header: Bool) -> [NSAttributedString] {
                cells.map { cell in
                    var inner = Builder()
                    var cellContext = context
                    cellContext.indent = 0
                    if header { cellContext.color = .secondaryLabelColor }
                    inner.inlines(cell.children, cellContext)
                    let text = NSMutableAttributedString(attributedString: inner.output)
                    if header {
                        // Smaller and semibold, like a column label; code
                        // stays in its own font.
                        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                            guard (value as? NSFont)?.isFixedPitch != true else { return }
                            text.addAttribute(.font, value: Self.tableHeaderFont, range: range)
                        }
                    }
                    return text
                }
            }
            rows.append(cells(table.head.cells, header: true))
            for row in table.body.rows { rows.append(cells(row.cells, header: false)) }
            let columns = rows.map(\.count).max() ?? 0
            guard columns > 0 else { return }

            // Natural widths, fitted to the widest reading column. A
            // narrower column scales the whole table down to fit.
            var natural = Array(repeating: 0.0, count: columns)
            for row in rows {
                for (index, cell) in row.enumerated() {
                    natural[index] = max(natural[index], Double(ceil(cell.size().width) + 1))
                }
            }
            let budget = Double(Theme.maxContentWidth - context.indent - CGFloat(columns - 1) * Self.cellPadH * 2)
            let widths = TableColumns.fit(natural, into: budget)

            let grid = NSTextTable()
            grid.numberOfColumns = columns
            grid.collapsesBorders = true
            grid.hidesEmptyCells = false
            let (lineStyle, offset) = Theme.lines(Theme.bodyLine, font: Theme.bodyFont)
            for (rowIndex, row) in rows.enumerated() {
                let isLast = rowIndex == rows.count - 1
                for column in 0..<columns {
                    let block = NSTextTableBlock(table: grid, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    block.setValue(CGFloat(widths[column]), type: .absoluteValueType, for: .width)
                    block.setWidth(Self.cellPadV, type: .absoluteValueType, for: .padding, edge: .minY)
                    // The paragraph gap after the table goes inside the last
                    // row (it has no rule): a margin there was ignored.
                    block.setWidth(Self.cellPadV + (isLast ? Self.paragraphGap : 0), type: .absoluteValueType, for: .padding, edge: .maxY)
                    // The first column's text lines up with the paragraphs
                    // around the table, and the last one ends at its text.
                    block.setWidth(column == 0 ? 0 : Self.cellPadH, type: .absoluteValueType, for: .padding, edge: .minX)
                    block.setWidth(column == columns - 1 ? 0 : Self.cellPadH, type: .absoluteValueType, for: .padding, edge: .maxX)
                    if column == 0, context.indent > 0 {
                        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
                    }
                    if !isLast {
                        block.setWidth(rowIndex == 0 ? 1 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                        block.setBorderColor(rowIndex == 0 ? Theme.cardBorder : Theme.hairline, for: .maxY)
                    }
                    let style = lineStyle.mutableCopy() as! NSMutableParagraphStyle
                    style.paragraphSpacing = 0
                    style.textBlocks = [block]
                    let start = output.length
                    // An empty cell still needs a character: the message's
                    // trailing newlines are trimmed, and an empty last cell
                    // would lose its paragraph (and its column).
                    let cell = column < row.count ? row[column] : NSAttributedString()
                    if cell.length > 0 { output.append(cell) } else { append("\u{200B}", context) }
                    append("\n", Context())
                    let range = NSRange(location: start, length: output.length - start)
                    output.addAttribute(.paragraphStyle, value: style, range: range)
                    output.addAttribute(.baselineOffset, value: offset, range: range)
                }
            }
        }

        static var tableHeaderFont: NSFont { .systemFont(ofSize: TypeScale.label, weight: .semibold) }

        // MARK: Inlines

        /// Marks thread-id-shaped words appended since `start`. Whether one
        /// is a real thread is only known when it's drawn (the thread list
        /// changes; renders are cached by their text), so this is just the
        /// shape. A link keeps its own destination.
        func markThreadRefs(from start: Int, _ context: Context) {
            guard context.link == nil, output.length > start else { return }
            let text = output.mutableString.substring(from: start)
            for found in ThreadRefs.candidates(in: text) {
                let range = NSRange(location: start + found.location, length: found.length)
                output.addAttribute(.tbThreadRef, value: output.mutableString.substring(with: range), range: range)
            }
        }

        mutating func inlines(_ children: MarkupChildren, _ context: Context) {
            for child in children { inline(child, context) }
        }

        mutating func inline(_ markup: Markup, _ context: Context) {
            switch markup {
            case let text as Markdown.Text:
                let start = output.length
                append(text.string, context)
                markThreadRefs(from: start, context)
            case let emphasis as Emphasis:
                var inner = context
                inner.italic = true
                inlines(emphasis.children, inner)
            case let strong as Strong:
                var inner = context
                inner.bold = true
                inlines(strong.children, inner)
            case let strike as Strikethrough:
                var inner = context
                inner.strike = true
                inlines(strike.children, inner)
            case let code as InlineCode:
                var inner = context
                inner.code = true
                if inner.link == nil, FilePathRefs.looksLikePath(code.code) { inner.link = FilePathRefs.url(for: code.code) }
                // BackgroundLayoutManager draws the pill `pillPad` past the
                // glyphs on each side, which ate most of the word space
                // around it. Kerning the characters either side reserves
                // that room (and a little more) without changing the text.
                let start = output.length
                if start > 0, ![9, 10, 0x2028].contains(output.mutableString.character(at: start - 1)) {
                    output.addAttribute(.kern, value: MarkdownRenderer.pillKern, range: NSRange(location: start - 1, length: 1))
                }
                append(code.code, inner)
                markThreadRefs(from: start, context)
                if output.length > start {
                    output.addAttribute(.kern, value: MarkdownRenderer.pillKern, range: NSRange(location: output.length - 1, length: 1))
                }
            case let link as Markdown.Link:
                var inner = context
                inner.link = link.destination.flatMap(MarkdownRenderer.linkURL)
                inlines(link.children, inner)
                // A link into the turn's own working says it goes up the
                // thread, not out of it (docs/end-turn-design).
                if let url = inner.link, WorkLinks.quote(of: url) != nil { append("\u{2009}↑", inner) }
            case let image as Markdown.Image:
                var inner = context
                inner.link = image.source.flatMap(MarkdownRenderer.linkURL)
                let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
                // A picture on this Mac is drawn in the text; a web address,
                // or a file that's gone, stays a link with its alt text.
                if let url = inner.link, url.isFileURL, let attachment = MarkdownRenderer.picture(path: url.path, alt: alt) {
                    let run = NSMutableAttributedString(attachment: attachment)
                    run.addAttributes([.link: url, .toolTip: alt], range: NSRange(location: 0, length: run.length))
                    output.append(run)
                } else {
                    append("[\(alt)]", inner)
                }
            case is SoftBreak:
                append(" ", context)
            case is LineBreak:
                append("\u{2028}", context)
            case let html as InlineHTML:
                var inner = context
                inner.color = .secondaryLabelColor
                append(html.rawHTML, inner)
            case let symbol as SymbolLink:
                var inner = context
                inner.code = true
                append(symbol.destination ?? "", inner)
            default:
                if markup.childCount > 0 {
                    for child in markup.children { inline(child, context) }
                } else {
                    append(markup.format(), context)
                }
            }
        }
    }
}
