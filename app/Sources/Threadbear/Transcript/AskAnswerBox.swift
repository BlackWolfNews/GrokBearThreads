import AppKit
import ThreadbearCore
import UniformTypeIdentifiers

/// The sizes of an ask's Something else box, shared by the renderer (which
/// leaves room for it in the card's text, off the main thread too) and the
/// box itself, so the two always agree.
enum AskBoxMetrics {
    static var font: NSFont { .systemFont(ofSize: TypeScale.composer) }
    /// The composer's line height, so an answer types like a message.
    static var lineHeight: CGFloat { TypeScale.bodyLine }
    static var padH: CGFloat { zoomed(10) }
    static var padV: CGFloat { zoomed(6) }
    /// Space above the box, between it and the answer buttons.
    static var gap: CGFloat { zoomed(8) }
    /// The picture button at the box's right edge, and the room left for it.
    static var buttonSide: CGFloat { zoomed(22) }
    static var thumb: CGFloat { zoomed(44) }
    static var thumbGap: CGFloat { zoomed(6) }
    /// It grows to this many lines, then scrolls.
    static let maxLines = 8

    static var attributes: [NSAttributedString.Key: Any] {
        let (style, offset) = Theme.lines(lineHeight, font: font)
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style, .baselineOffset: offset]
    }

    /// The width the text wraps at in a box `width` wide.
    static func textWidth(_ width: CGFloat) -> CGFloat {
        max(40, width - padH * 2 - buttonSide - zoomed(4))
    }

    /// Lines the text takes at `width`: one at least, `maxLines` at most.
    static func lines(_ text: String, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        let rect = NSAttributedString(string: text, attributes: attributes)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        var lines = Int((ceil(rect.height) / lineHeight).rounded())
        // A new line typed at the end isn't in the measured height yet.
        if text.hasSuffix("\n") { lines += 1 }
        return min(maxLines, max(1, lines))
    }

    /// The box's height for what's in it, in a box `width` wide.
    static func height(_ note: AskNote, width: CGFloat) -> CGFloat {
        let text = CGFloat(lines(note.text, width: textWidth(width))) * lineHeight
        return padV * 2 + text + (note.images.isEmpty ? 0 : thumb + thumbGap)
    }
}

/// An ask's Something else box on the open card: a small composer of its
/// own, under the ask's buttons, so each ask can have an answer in Mike's
/// words (Mike, 30 Oct, option A of the review). Paste or drop pictures in
/// it, or use its picture button, as in the composer; Return sends the lot,
/// Shift-Return adds a line. The card leaves room for it (`.tbAnswerBox`)
/// and TextRowCell puts it there.
final class AskAnswerBox: NSView {
    let textView = ComposerTextField.makeTextView()
    private let scroll = OverlayScrollView()
    private let addButton = NSButton()
    private var thumbs: [NSView] = []
    private(set) var note = AskNote()
    private var responderWatch: NSKeyValueObservation?
    private var zoomObserver: NSObjectProtocol?

    /// What's in it changed: his words, or a picture taken out.
    var onChange: ((AskNote) -> Void)?
    var onImages: (([URL]) -> Void)?
    var onSend: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = zoomed(8)
        layer?.borderWidth = 1
        textView.delegate = self
        textView.inAnswerBox = true
        textView.placeholder = "Your answer"
        textView.onSend = { [weak self] in self?.onSend?() }
        // Nothing typed: Return still sends, as the pictures or the other
        // picks may be the answer.
        textView.onReturnWhenEmpty = { [weak self] in
            self?.onSend?()
            return true
        }
        textView.onImages = { [weak self] urls in self?.onImages?(urls) }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.imagePosition = .imageOnly
        addButton.target = self
        addButton.action = #selector(choosePictures)
        addButton.setTip("Add pictures to this answer (or paste or drop them in the box)")
        addButton.setAccessibilityLabel("Add pictures")
        addSubview(addButton)
        updateBorder()
        // A zoom change re-measures the card around it; the text follows.
        zoomObserver = NotificationCenter.default.addObserver(forName: TextZoom.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textView.applyTypeScale()
                self.layer?.cornerRadius = zoomed(8)
                self.needsLayout = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    /// Shows what's in the box (the card's copy). His typing is already
    /// in it, so only a change from elsewhere (a send, a picture landing,
    /// a script) touches the text.
    func show(_ note: AskNote) {
        let oldImages = self.note.images
        self.note = note
        if textView.string != note.text { textView.replaceText(note.text) }
        if oldImages != note.images || thumbs.count != note.images.count { rebuildThumbs() }
        needsLayout = true
    }

    func focus() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    override func layout() {
        super.layout()
        let padH = AskBoxMetrics.padH, padV = AskBoxMetrics.padV
        let side = AskBoxMetrics.buttonSide
        var y = padV
        if !note.images.isEmpty {
            var x = padH
            for thumb in thumbs {
                thumb.frame = NSRect(x: x, y: y, width: AskBoxMetrics.thumb, height: AskBoxMetrics.thumb)
                x += AskBoxMetrics.thumb + AskBoxMetrics.thumbGap
            }
            y += AskBoxMetrics.thumb + AskBoxMetrics.thumbGap
        }
        let textWidth = AskBoxMetrics.textWidth(bounds.width)
        scroll.frame = NSRect(x: padH, y: y, width: textWidth, height: max(AskBoxMetrics.lineHeight, bounds.height - y - padV))
        textView.frame.size.width = textWidth
        addButton.frame = NSRect(x: bounds.width - padH / 2 - side, y: bounds.height - padV - (AskBoxMetrics.lineHeight + side) / 2, width: side, height: side)
        let image = Symbols.image("photo.badge.plus", size: 13)
        if addButton.image !== image { addButton.image = image }
        addButton.contentTintColor = .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    /// Accent while he's typing in it, like a focused field; a hairline
    /// otherwise, on the field background the composer card uses.
    private func updateBorder() {
        let focused = window?.firstResponder === textView
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.35).cgColor
        }
    }

    private func rebuildThumbs() {
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = note.images.enumerated().map { index, image in
            let thumb = AnswerThumb(path: image.path)
            thumb.onRemove = { [weak self] in self?.removeImage(at: index) }
            addSubview(thumb)
            return thumb
        }
    }

    private func removeImage(at index: Int) {
        guard note.images.indices.contains(index) else { return }
        var changed = note
        changed.images.remove(at: index)
        onChange?(changed)
    }

    @objc private func choosePictures() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            if response == .OK { self?.onImages?(panel.urls) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}

extension AskAnswerBox: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        var changed = note
        changed.text = textView.string
        note = changed
        onChange?(changed)
    }

}

extension AskAnswerBox {
    /// The outline follows the cursor in and out of the box, typed in or
    /// not (Something else puts the cursor there before a key is pressed).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateBorder() }
        }
        updateBorder()
    }
}

/// A picture in an answer box, with × to take it out while the pointer is
/// over it, like the composer's.
private final class AnswerThumb: NSView {
    private let imageView = NSImageView()
    private let remove = NSButton()
    var onRemove: (() -> Void)?

    override var isFlipped: Bool { true }

    init(path: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = zoomed(6)
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspectFill
        addSubview(imageView)
        remove.isBordered = false
        remove.bezelStyle = .regularSquare
        remove.imagePosition = .imageOnly
        remove.image = Symbols.image("xmark.circle.fill", size: 13, weight: .semibold)
        remove.contentTintColor = .white
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.isHidden = true
        remove.setTip("Remove")
        remove.setAccessibilityLabel("Remove picture")
        addSubview(remove)
        ThumbnailLoader.shared.load(path: path, maxPixels: Int(AskBoxMetrics.thumb * 4)) { [weak self] image in
            guard let self, let image else { return }
            // Filled into the square, as the composer's are.
            self.imageView.image = nil
            self.imageView.layer?.contents = image
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let side = zoomed(18)
        remove.frame = NSRect(x: bounds.width - side - zoomed(2), y: zoomed(2), width: side, height: side)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { remove.isHidden = false }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }

    @objc private func removeClicked() { onRemove?() }
}
