import AppKit
import Markdown
import ThreadbareCore

/// Renders markdown into an `NSAttributedString` for TextKit 1 text views.
/// Text is split into top-level blocks (`MarkdownBlocks`) and each block is
/// rendered once and cached by its text, so a streaming message only
/// re-renders its last, still-open block. Safe to call off the main thread.
enum MarkdownRenderer {
    struct Rendered {
        let string: NSAttributedString
        let blocks: [String]
        /// UTF-16 offset where each block starts in `string`.
        let starts: [Int]
    }

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
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(separator) }
            starts.append(output.length)
            output.append(renderBlock(block))
        }
        return Rendered(string: output, blocks: blocks, starts: starts)
    }

    static func renderBlock(_ block: String) -> NSAttributedString {
        let key = block as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let document = Document(parsing: block, options: [.disableSmartOpts])
        var builder = Builder()
        for child in document.children {
            builder.block(child, Context())
        }
        builder.trimTrailingNewline()
        let result = NSAttributedString(attributedString: builder.output)
        cache.setObject(result, forKey: key, cost: block.utf16.count)
        return result
    }

    private static let separator = NSAttributedString(string: "\n", attributes: Theme.bodyAttributes)

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

        mutating func trimTrailingNewline() {
            while output.length > 0, output.string.utf16.last == 10 {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        func font(_ context: Context) -> NSFont {
            if context.code { return context.bold ? Theme.codeBoldFont : Theme.codeFont }
            var font: NSFont
            switch context.headingLevel {
            case 1: font = .systemFont(ofSize: 19, weight: .semibold)
            case 2: font = .systemFont(ofSize: 16.5, weight: .semibold)
            case 3: font = .systemFont(ofSize: 14.5, weight: .semibold)
            case 4...: font = .systemFont(ofSize: Theme.bodySize, weight: .semibold)
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
            }
            return attributes
        }

        func append(_ text: String, _ context: Context) {
            output.append(NSAttributedString(string: text, attributes: attributes(context)))
        }

        func paragraphStyle(_ context: Context, spacing: CGFloat? = nil, before: CGFloat = 0, first: CGFloat? = nil, tabs: [CGFloat] = []) -> NSParagraphStyle {
            let style = Theme.paragraph(spacing: spacing ?? context.listSpacing ?? 9, before: before, head: context.indent, first: first)
            if !tabs.isEmpty {
                style.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
                style.defaultTabInterval = 28
            }
            return style
        }

        mutating func finishParagraph(from start: Int, style: NSParagraphStyle) {
            append("\n", Context())
            output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        }

        // MARK: Blocks

        mutating func block(_ markup: Markup, _ context: Context, listPrefix: String? = nil) {
            switch markup {
            case let paragraph as Paragraph:
                let start = output.length
                var first: CGFloat?
                var tabs: [CGFloat] = []
                if let listPrefix {
                    append(listPrefix + "\t", context)
                    first = max(0, context.indent - 18)
                    tabs = [context.indent]
                }
                inlines(paragraph.children, context)
                finishParagraph(from: start, style: paragraphStyle(context, first: first, tabs: tabs))

            case let heading as Heading:
                var inner = context
                inner.headingLevel = heading.level
                let start = output.length
                inlines(heading.children, inner)
                finishParagraph(from: start, style: paragraphStyle(context, spacing: 5, before: heading.level <= 2 ? 6 : 3))

            case let code as CodeBlock:
                codeBlock(code.code, context)

            case let quote as BlockQuote:
                var inner = context
                inner.indent += 14
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

        mutating func listItems(_ items: [ListItem], _ context: Context, marker: (Int, ListItem) -> String) {
            var inner = context
            inner.indent += 20
            for (index, item) in items.enumerated() {
                var itemContext = inner
                itemContext.listSpacing = index == items.count - 1 && context.listSpacing == nil ? 9 : 3
                var first = true
                for child in item.children {
                    if first, child is Paragraph {
                        block(child, itemContext, listPrefix: marker(index, item))
                    } else {
                        if first {
                            // A list item that starts with something other than text still gets its marker.
                            let start = output.length
                            append(marker(index, item), itemContext)
                            finishParagraph(from: start, style: paragraphStyle(itemContext, spacing: 2, first: max(0, itemContext.indent - 18)))
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
            // after applies once around the whole box.
            let body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
            let style = Theme.paragraph(lineHeight: 1.15, spacing: 18, before: 10, head: context.indent + 12, tail: -12)
            style.lineBreakMode = .byCharWrapping
            let start = output.length
            output.append(NSAttributedString(string: body, attributes: [
                .font: Theme.codeFont,
                .foregroundColor: NSColor.labelColor,
                .tbBlockBackground: Theme.codeBackground,
            ]))
            append("\n", Context())
            output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        }

        mutating func renderTable(_ table: Markdown.Table, _ context: Context) {
            var rows: [[NSAttributedString]] = []
            func cells(_ cells: some Sequence<Markdown.Table.Cell>, bold: Bool) -> [NSAttributedString] {
                cells.map { cell in
                    var inner = Builder()
                    var cellContext = context
                    cellContext.bold = bold
                    inner.inlines(cell.children, cellContext)
                    return NSAttributedString(attributedString: inner.output)
                }
            }
            rows.append(cells(table.head.cells, bold: true))
            for row in table.body.rows { rows.append(cells(row.cells, bold: false)) }
            let columns = rows.map(\.count).max() ?? 0
            var widths = Array(repeating: CGFloat(0), count: columns)
            for row in rows {
                for (index, cell) in row.enumerated() {
                    widths[index] = max(widths[index], min(260, ceil(cell.size().width)))
                }
            }
            var stops: [CGFloat] = []
            var x = context.indent
            for width in widths.dropLast() {
                x += width + 18
                stops.append(x)
            }
            for (rowIndex, row) in rows.enumerated() {
                let start = output.length
                for (index, cell) in row.enumerated() {
                    if index > 0 { append("\t", context) }
                    output.append(cell)
                }
                let style = paragraphStyle(context, spacing: rowIndex == rows.count - 1 ? 9 : 3, tabs: stops)
                finishParagraph(from: start, style: style)
            }
        }

        // MARK: Inlines

        mutating func inlines(_ children: MarkupChildren, _ context: Context) {
            for child in children { inline(child, context) }
        }

        mutating func inline(_ markup: Markup, _ context: Context) {
            switch markup {
            case let text as Markdown.Text:
                append(text.string, context)
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
                append(code.code, inner)
            case let link as Markdown.Link:
                var inner = context
                inner.link = link.destination.flatMap(URL.init(string:))
                inlines(link.children, inner)
            case let image as Markdown.Image:
                var inner = context
                inner.link = image.source.flatMap(URL.init(string:))
                let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
                append("[\(alt)]", inner)
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
