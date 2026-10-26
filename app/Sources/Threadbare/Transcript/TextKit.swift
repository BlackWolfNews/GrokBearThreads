import AppKit

/// TextKit 1 layout manager that also draws the transcript's custom
/// backgrounds: rounded boxes behind code blocks and full-width line fills
/// for diffs. Plain `.backgroundColor` only covers the glyphs.
final class BackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        let width = container.size.width

        var drawnBlocks = Set<Int>()
        storage.enumerateAttribute(.tbBlockBackground, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            var effective = NSRange()
            _ = storage.attribute(.tbBlockBackground, at: range.location, longestEffectiveRange: &effective, in: whole)
            guard drawnBlocks.insert(effective.location).inserted else { return }
            let glyphs = glyphRange(forCharacterRange: effective, actualCharacterRange: nil)
            var box = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                box = box.union(used)
            }
            guard !box.isNull else { return }
            let style = storage.attribute(.paragraphStyle, at: effective.location, effectiveRange: nil) as? NSParagraphStyle
            let pad = MarkdownRenderer.codePad
            let head = (style?.headIndent ?? 0) - pad
            let tail = width + (style?.tailIndent ?? 0) + pad
            var rect = NSRect(x: head, y: box.minY - pad, width: max(0, tail - head), height: box.height + pad * 2)
            rect.origin.y = max(0, rect.origin.y)
            rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.25, dy: 0.25)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            color.setFill()
            path.fill()
            Theme.cardBorder.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        storage.enumerateAttribute(.tbInlineBackground, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Theme.codeFont
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            color.setFill()
            // One pill per line the run covers, sized to the font rather than
            // the line (which includes the paragraph's extra line height).
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, textContainer, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                var box = self.boundingRect(forGlyphRange: part, in: textContainer)
                // The run's last character is kerned to make room for the
                // pill (MarkdownRenderer); that space isn't part of the glyphs.
                let last = self.characterIndexForGlyph(at: NSMaxRange(part) - 1)
                if let kern = storage.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat {
                    box.size.width = max(0, box.width - kern)
                }
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                box.origin.y = baseline - font.ascender - 1.5
                box.size.height = font.ascender - font.descender + 3
                box = box.insetBy(dx: -MarkdownRenderer.pillPad, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            }
        }

        storage.enumerateAttribute(.tbLineBackground, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            color.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                NSRect(x: origin.x, y: rect.minY + origin.y, width: width, height: rect.height).fill()
            }
        }
    }
}

/// Measures attributed strings with a private TextKit 1 stack. One per
/// thread (TextKit 1 objects are fine off the main thread when they aren't
/// attached to a view).
final class TextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
    }

    /// Height and the widest line's width.
    func measure(_ string: NSAttributedString, width: CGFloat) -> NSSize {
        guard string.length > 0 else { return .zero }
        container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(string)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        storage.setAttributedString(NSAttributedString())
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    static var current: TextMeasurer {
        let key = "com.mikerosoft.threadbare.measurer"
        if let measurer = Thread.current.threadDictionary[key] as? TextMeasurer { return measurer }
        let measurer = TextMeasurer()
        Thread.current.threadDictionary[key] = measurer
        return measurer
    }
}

/// A read-only, selectable TextKit 1 text view for transcript text.
final class TranscriptTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = BackgroundLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
    }

    // MARK: Drawing tall text through a window
    //
    // A layer-backed view keeps a backing store the size of its whole frame:
    // a 2,864 pt streaming reply cost 36 MB at 2x, and an expanded 1,500-line
    // diff would cost hundreds. So text taller than about a screen and a half
    // is drawn through a window ("slice") over the part that's on screen plus
    // half a screen either side. The view's frame is the slice, and its
    // bounds origin is moved by the slice's offset, so text coordinates,
    // selection and clicks are the same as for the whole frame.

    /// Where all of the text sits in the superview (what `frame` would be).
    private(set) var fullFrame = NSRect.zero

    /// The text always starts at (0, 0) in the view's coordinates, whatever
    /// slice the bounds show. NSTextView recomputes this from the bounds
    /// origin when it re-lays out (a finished reply replacing its streamed
    /// text did it), and a slice at offset 2,844 then drew the start of a
    /// long reply where its end belonged.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }
    private var placed = false

    /// Puts the text at `frame` in the superview, drawing only a slice of
    /// it if it's tall.
    func place(_ frame: NSRect) {
        fullFrame = frame
        placed = true
        updateSlice(force: true)
    }

    /// Moves the slice to cover what's on screen. Cheap when nothing needs
    /// to change; called as the transcript scrolls.
    func updateSlice(force: Bool = false) {
        guard placed else { return }
        let full = fullFrame
        let screen = max(200, enclosingScrollView?.contentView.bounds.height ?? 900)
        guard full.height > screen * 1.5, let superview else {
            apply(slice: 0..<full.height)
            return
        }
        // The slice drawn now, if it still fits the text.
        var current: Range<CGFloat>? = frame.height > 0 && !parked ? bounds.minY..<(bounds.minY + frame.height) : nil
        if let slice = current, slice.upperBound > full.height { current = nil }
        // The part of the text on screen, from the top of the text.
        let visible = superview.visibleRect.intersection(full)
        guard !visible.isNull, visible.height > 0 else {
            // Not on screen (yet): keep the slice it has, or start at the top.
            if force || current == nil { apply(slice: current ?? 0..<min(full.height, screen * 2)) }
            return
        }
        let top = visible.minY - full.minY
        let bottom = visible.maxY - full.minY
        let margin = screen * 0.5
        if let slice = current {
            // Keep the slice while what's on screen is inside it with some
            // room to scroll (or the slice already reaches that end of the text).
            let roomAbove = top - slice.lowerBound
            let roomBelow = slice.upperBound - bottom
            let enoughAbove = slice.lowerBound <= 0 || roomAbove >= margin / 3
            let enoughBelow = slice.upperBound >= full.height || roomBelow >= margin / 3
            if roomAbove >= 0, roomBelow >= 0, enoughAbove, enoughBelow {
                // The frame may still need to follow a moved or resized row.
                if force { apply(slice: slice) }
                return
            }
        }
        apply(slice: max(0, top - margin)..<min(full.height, bottom + margin))
    }

    private var parked = false

    /// Shrinks to nothing (letting go of its backing store) while its row
    /// is parked off screen. `updateSlice(force:)` brings it back.
    func park() {
        guard placed, !parked else { return }
        parked = true
        super.frame = NSRect(x: fullFrame.minX, y: fullFrame.minY, width: fullFrame.width, height: 0)
    }

    private func apply(slice: Range<CGFloat>) {
        parked = false
        let target = NSRect(x: fullFrame.minX, y: fullFrame.minY + slice.lowerBound, width: fullFrame.width, height: slice.upperBound - slice.lowerBound)
        var moved = false
        if frame != target {
            super.frame = target
            moved = true
        }
        if bounds.origin.y != slice.lowerBound || bounds.origin.x != 0 {
            setBoundsOrigin(NSPoint(x: 0, y: slice.lowerBound))
            moved = true
        }
        // The slice shows a different part of the text now: draw it afresh
        // rather than trust the old contents to be redrawn.
        if moved { needsDisplay = true }
    }

    /// Sets the text unless it's the same object already shown.
    func show(_ string: NSAttributedString, width: CGFloat) {
        if let container = textContainer, container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        guard let storage = textStorage else { return }
        if storage.length == string.length, storage.isEqual(to: string) { return }
        storage.setAttributedString(string)
        // The pointing hand over "Show 30 more lines" (always the last run)
        // only shows once the view rebuilds its cursor rects.
        if string.length > 0, string.attribute(.tbAction, at: string.length - 1, effectiveRange: nil) != nil {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Empties the text so a parked cell holds no layout.
    func clear() {
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.setAttributedString(NSAttributedString())
    }

    /// Replaces everything from `offset` on, so TextKit only lays out the tail.
    func replaceTail(from offset: Int, with tail: NSAttributedString) {
        guard let storage = textStorage else { return }
        let start = min(offset, storage.length)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()
    }

    var usedHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    /// Called with a `.tbAction` run's value when it's clicked. A plain
    /// attribute rather than a link, so it keeps its own colour (links are
    /// drawn in `linkTextAttributes`) and needs no URL scheme.
    var onAction: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onAction, let action = action(at: convert(event.locationInWindow, from: nil)) {
            onAction(action)
            return
        }
        super.mouseDown(with: event)
    }

    /// The `.tbAction` under `point` (view coordinates, which already
    /// include a slice's bounds offset), if the point is on its glyphs.
    private func action(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -4, dy: -3).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.tbAction, at: index, effectiveRange: nil) as? String
    }

    // Don't let a row's text view swallow scroll-wheel events or show an
    // insertion point; the table owns scrolling.
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Defer to the table's row menu (Copy message, Copy transcript) with
        // text-specific items first when there's a selection.
        let base = super.menu(for: event) ?? NSMenu()
        if let tableMenu = enclosingTableMenu(for: event) {
            if selectedRange().length == 0 { return tableMenu }
            base.addItem(.separator())
            for item in tableMenu.items { base.addItem(item.copy() as! NSMenuItem) }
        }
        return base
    }

    private func enclosingTableMenu(for event: NSEvent) -> NSMenu? {
        var view: NSView? = superview
        while let current = view {
            if let table = current as? TranscriptTableView {
                return table.menu(for: event)
            }
            view = current.superview
        }
        return nil
    }
}
