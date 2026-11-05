import AppKit
import ThreadbearCore

/// A Notion card or another thread mentioned among the words
/// (`CardMentions`): a small rounded tag with the card's or thread's title,
/// in place of the raw link (Mike asked 3 Nov, for threads 5 Nov).
/// It looks like a picture's chip, so a message's chips read as one family.
enum CardChip {
    /// A long title is cut off rather than taking the whole line.
    private static var maxLabel: CGFloat { zoomed(230) }

    private static func label(_ title: String, metrics: PictureChip.Metrics) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [
            .font: metrics.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }

    static func size(_ title: String, metrics: PictureChip.Metrics) -> NSSize {
        let words = min(maxLabel, label(title, metrics: metrics).size().width.rounded(.up))
        return NSSize(width: (metrics.inset + metrics.icon + metrics.gap + words + metrics.trailing).rounded(.up), height: metrics.height)
    }

    /// A card's icon, or a speech bubble for a thread.
    private static func symbol(_ kind: CardMentions.Kind) -> (name: String, label: String) {
        kind == .thread ? ("bubble.left", "Thread") : ("square.text.square", "Notion card")
    }

    static func draw(in rect: NSRect, title: String, kind: CardMentions.Kind = .card, metrics: PictureChip.Metrics) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: metrics.radius, yRadius: metrics.radius)
        PictureChip.fill.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        let icon = NSRect(x: rect.minX + metrics.inset, y: rect.midY - metrics.icon / 2, width: metrics.icon, height: metrics.icon)
        if let symbol = NSImage(systemSymbolName: symbol(kind).name, accessibilityDescription: symbol(kind).label)?
            .withSymbolConfiguration(.init(pointSize: metrics.icon * 0.78, weight: .regular)) {
            let size = symbol.size
            let tinted = NSImage(size: size, flipped: false) { box in
                // The colour cut to the symbol's shape, as a picture chip's is.
                NSColor.secondaryLabelColor.set()
                box.fill(using: .copy)
                symbol.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            let box = NSRect(x: icon.midX - size.width / 2, y: icon.midY - size.height / 2, width: size.width, height: size.height)
            tinted.draw(in: box.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let words = label(title, metrics: metrics)
        let height = words.size().height
        // As a picture chip's label: centred whichever way up the context is.
        let box = NSRect(x: icon.maxX + metrics.gap, y: (rect.midY - height / 2).rounded(), width: rect.maxX - metrics.trailing - icon.maxX - metrics.gap, height: height)
        words.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Mike's bubble: the chip as an attachment that draws itself.
    static func attachment(title: String, kind: CardMentions.Kind = .card, font: NSFont) -> NSTextAttachment {
        let metrics = PictureChip.Metrics(font: font)
        let size = size(title, metrics: metrics)
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, title: title, kind: kind, metrics: metrics)
            return true
        }
        attachment.bounds = NSRect(x: 0, y: metrics.baselineOffset, width: size.width, height: size.height)
        return attachment
    }
}

/// A card or thread in the composer's words. It carries the link it stands
/// for, so the draft read off the text is the same plain link the message
/// will hold.
final class CardAttachment: NSTextAttachment {
    let reference: String
    let title: String
    let kind: CardMentions.Kind

    init(reference: String, title: String, kind: CardMentions.Kind = .card) {
        self.reference = reference
        self.title = title
        self.kind = kind
        super.init(data: nil, ofType: nil)
        let cell = CardChipCell()
        attachmentCell = cell
        cell.attachment = self
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}

/// Draws a `CardAttachment` in the composer (TextKit 1).
final class CardChipCell: NSTextAttachmentCell {
    private var card: CardAttachment? { attachment as? CardAttachment }
    private var metrics: PictureChip.Metrics { PictureChip.Metrics(font: ComposerTextField.font) }

    override func cellSize() -> NSSize { CardChip.size(card?.title ?? "", metrics: metrics) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: metrics.baselineOffset) }

    // A click puts the cursor beside it, as on a word.
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        CardChip.draw(in: cellFrame, title: card?.title ?? "", kind: card?.kind ?? .card, metrics: metrics)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
