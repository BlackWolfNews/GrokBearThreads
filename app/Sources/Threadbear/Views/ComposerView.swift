import AppKit
import SwiftUI
import ThreadbearCore
import UniformTypeIdentifiers

/// The message box: a rounded card the width of the transcript column.
/// Return sends, Shift-Return adds a line (carrying a markdown list on), paste, drop or "+" adds images,
/// and the row under the text holds the account, model and permission
/// chips (and the folder's, away from the default) and send (or Stop).
struct ComposerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let thread: ThreadSummary?
    @State private var height: CGFloat = ComposerTextField.minHeight
    @State private var importing = 0

    static var cornerRadius: CGFloat { zoomed(20) }
    static var padding: CGFloat { zoomed(14) }

    private var draftKey: String { thread?.id ?? "new" }

    var body: some View {
        let draft = Binding<Draft>(
            get: { app.drafts[draftKey] ?? Draft() },
            set: { app.drafts[draftKey] = $0 }
        )
        // Answers picked on the open card of asks, in the transcript, wait
        // here as chips and go with the message (AnswerChips).
        let picks = thread.map { app.picks(for: $0) } ?? [:]
        let canSend = !picks.isEmpty || ComposerChips.canSend(text: draft.wrappedValue.text, imageCount: draft.wrappedValue.images.count)
        // A new thread on its way: what was sent stays, greyed and locked,
        // until the runner has made the thread.
        let creating = thread == nil && app.creatingThread
        VStack(alignment: .leading, spacing: zoomed(6)) {
        VStack(alignment: .leading, spacing: zoomed(10)) {
            if let thread, let edit = app.editing[thread.id] {
                EditingBanner(sending: edit.sending) { app.cancelEditing(threadId: thread.id) }
            } else if let thread, !picks.isEmpty {
                AnswerChips(thread: thread, picks: picks)
            }
            // The folder's actions (patches), above the text as in the design.
            if let thread, !thread.actions.isEmpty {
                ActionChips(thread: thread)
            }
            if !draft.wrappedValue.images.isEmpty || importing > 0 {
                AttachmentStrip(images: draft.images, importing: importing)
                    .disabled(creating)
                    .opacity(creating ? 0.5 : 1)
            }
            ComposerTextField(
                text: draft.text,
                height: $height,
                focusTrigger: app.focusRequests[draftKey] ?? 0,
                placeholder: placeholder(picks),
                onSend: { send() },
                onReturnWhenEmpty: { returnWhenEmpty(draft.wrappedValue) },
                onImages: { urls in attach(urls, to: draft) },
                onEscape: { cancelEdit() },
                editable: !creating
            )
            .frame(height: height)
            .opacity(creating ? 0.5 : 1)
            ComposerControls(
                thread: thread,
                running: thread?.status.isBusy == true,
                canSend: canSend,
                sending: creating,
                onAttach: { chooseImages(for: draft) },
                onSend: { send() },
                onSchedule: { app.newSchedule(from: thread, draftKey: draftKey) }
            )
        }
        .padding(Self.padding)
        .background { card }
        }
        // The transcript's reading column: 780 wide at most at 100%,
        // centred, with the same side insets once the window is narrower.
        .frame(maxWidth: Theme.maxContentWidth)
        .padding(.horizontal, Theme.sideInset)
        // At 12 the card looked wedged against the window's rounded bottom
        // corners; Codex and T3 leave about 24.
        .padding(.bottom, zoomed(20))
        .padding(.top, zoomed(4))
    }

    /// A lighter fill on dark; on light, white lifted off the page by a
    /// soft shadow. Clicking the card's padding puts the cursor in the text.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        return shape
            // About #2e2e2e on the #1c1c1c pane: at 0.05 the card was barely
            // lighter than the pane and read as an outline, not a card.
            .fill(dark ? Color.primary.opacity(0.085) : Color.white)
            .shadow(color: .black.opacity(dark ? 0 : 0.08), radius: zoomed(14), y: zoomed(4))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .contentShape(shape)
            .onTapGesture { app.focusComposer(draftKey) }
    }

    /// Esc while editing a message leaves the edit.
    private func cancelEdit() -> Bool {
        guard let thread, app.editing[thread.id] != nil else { return false }
        app.cancelEditing(threadId: thread.id)
        return true
    }

    /// With "Something else" picked, the box is that ask's answer.
    private func placeholder(_ picks: [Int: Int]) -> String {
        if let thread, app.editing[thread.id] != nil { return "Your message…" }
        if let thread, let own = picks.first(where: { $0.value == Decisions.ownAnswer })?.key, thread.asks.indices.contains(own) {
            return thread.asks.count == 1 ? "Your answer…" : "Your answer to \(own + 1)…"
        }
        return picks.isEmpty ? "Message" : "Add anything else…"
    }

    /// AppModel empties the box, and puts the draft back if it isn't sent.
    /// Picked answers go with it.
    private func send() {
        app.send(threadId: thread?.id)
    }

    /// Return with nothing typed sends picked answers on their own, or
    /// else allows the sole approval (below).
    private func returnWhenEmpty(_ draft: Draft) -> Bool {
        // An edit with only pictures left still sends; an empty one does nothing.
        if let thread, app.editing[thread.id] != nil {
            if !draft.images.isEmpty { send() }
            return true
        }
        if let thread, !app.picks(for: thread).isEmpty {
            send()
            return true
        }
        return draft.images.isEmpty && allowSoleApproval()
    }

    /// Return in an empty box allows the open thread's approval card, the
    /// ⏎ its Allow button shows, when there's exactly one waiting (with
    /// two, Return can't know which). Read when the key is pressed, so the
    /// composer doesn't redraw as approvals come and go.
    private func allowSoleApproval() -> Bool {
        guard let thread else { return false }
        let session = app.session(for: thread.id)
        let pending = session.model.pendingApprovalIds
        guard pending.count == 1, let id = pending.first else { return false }
        session.respond(approvalId: id, decision: .allow, answers: nil, message: nil)
        return true
    }

    /// Paste, drop and the "+" button all end up here: each file goes
    /// through the runner's `media.import` into the draft.
    private func attach(_ urls: [URL], to draft: Binding<Draft>) {
        guard !urls.isEmpty else { return }
        importing += urls.count
        Task {
            let refs = await app.importImages(urls)
            importing -= urls.count
            draft.wrappedValue.images += refs
        }
    }

    private func chooseImages(for draft: Binding<Draft>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK { attach(panel.urls, to: draft) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// Over the text while one of Mike's messages is being edited: what
/// sending will do, and the way out.
private struct EditingBanner: View {
    let sending: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
            Image(systemName: "pencil")
                .font(.system(size: TypeScale.sidebarMeta))
                .foregroundStyle(.secondary)
            Text(sending
                 ? "Cutting the thread back to this message…"
                 : "Editing a message. Sending cuts the thread back to it and undoes the agent's file changes since.")
                .font(.system(size: TypeScale.sidebarMeta + 1))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: zoomed(8))
            if sending {
                ProgressView().controlSize(.small)
            } else {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.link)
                    .font(.system(size: TypeScale.sidebarMeta + 1))
                    .tip("Stop editing and put back what was in the box (Esc)")
            }
        }
    }
}

private struct AttachmentStrip: View {
    @Binding var images: [ImageRef]
    let importing: Int

    var body: some View {
        HStack(spacing: zoomed(8)) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                AttachmentThumbnail(path: image.path) { images.remove(at: index) }
            }
            // One placeholder per image still being imported, so the strip
            // doesn't jump when they arrive.
            ForEach(0..<importing, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AttachmentThumbnail.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: AttachmentThumbnail.size, height: AttachmentThumbnail.size)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
    }
}

struct AttachmentThumbnail: View {
    let path: String
    let onRemove: () -> Void
    @State private var hovering = false

    static var size: CGFloat { zoomed(56) }
    static var cornerRadius: CGFloat { zoomed(8) }
    /// Screenshots show the remove badge without a real hover.
    static var debugShowRemove = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        AsyncThumbnail(path: path)
            .frame(width: Self.size, height: Self.size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if hovering || Self.debugShowRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: zoomed(8), weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: zoomed(18), height: zoomed(18))
                            .background(Circle().fill(.black.opacity(0.72)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(zoomed(4))
                    .tip("Remove")
                    .accessibilityLabel("Remove image")
                }
            }
            .onHover { hovering = $0 }
    }
}

private struct AsyncThumbnail: View {
    let path: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
        }
        .onAppear {
            // Filled into a square, so the short side needs the 2x pixels:
            // decode a bit larger than the tile or wide shots come out soft.
            ThumbnailLoader.shared.load(path: path, maxPixels: Int(AttachmentThumbnail.size * 4)) { image = $0 }
        }
    }
}

/// NSTextView-backed field that grows with its text: two lines at least,
/// ten at most, then it scrolls.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusTrigger: Int
    var placeholder: String
    var onSend: () -> Void
    /// Return with nothing typed: true if it did something.
    var onReturnWhenEmpty: () -> Bool = { false }
    var onImages: ([URL]) -> Void
    /// Esc: true if it did something (left an edit).
    var onEscape: () -> Bool = { false }
    /// False while what's in it is being sent (a new thread being made).
    var editable = true

    // Computed, so they follow the zoom (`applyTypeScale` re-applies
    // them to a text view that's already up).
    static var font: NSFont { .systemFont(ofSize: TypeScale.composer) }
    /// The transcript's fixed body line height, glyphs centred in it, so a
    /// message keeps its rhythm when it's sent (at 18 + 3 spacing the box
    /// was denser than the bubble it became).
    static var lineHeight: CGFloat { TypeScale.bodyLine }
    static var attributes: [NSAttributedString.Key: Any] {
        let font = font
        let (style, offset) = Theme.lines(lineHeight, font: font)
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style, .baselineOffset: offset]
    }
    /// Two lines, before the first measure comes in.
    static var minHeight: CGFloat { lineHeight * 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        let scroll = OverlayScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        context.coordinator.watchWidth(of: scroll)
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scroll
    }

    static func makeTextView() -> ComposerTextView {
        let textView = ComposerTextView()
        textView.textColor = .labelColor
        textView.applyTypeScale()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // No inset or padding, so the text's left edge lines up with the
        // chips under it and the height is whole lines.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    /// The box height for the text as laid out now: whole lines, two to ten.
    static func fittingHeight(of textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return minHeight }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        return ComposerChips.boxHeight(textHeight: used, lineHeight: lineHeight)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        textView.onSend = onSend
        textView.onReturnWhenEmpty = onReturnWhenEmpty
        textView.onImages = onImages
        textView.onEscape = onEscape
        textView.placeholder = placeholder
        if textView.isEditable != editable { textView.isEditable = editable }
        if textView.string != text {
            textView.replaceText(text)
            context.coordinator.updateHeight()
        }
        if context.coordinator.lastFocus != focusTrigger {
            context.coordinator.lastFocus = focusTrigger
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextField
        weak var textView: ComposerTextView?
        var lastFocus = 0
        private var lastWidth: CGFloat = 0
        private var widthObserver: NSObjectProtocol?
        private var zoomObserver: NSObjectProtocol?

        init(_ parent: ComposerTextField) {
            self.parent = parent
            lastFocus = parent.focusTrigger
            super.init()
            zoomObserver = NotificationCenter.default.addObserver(forName: TextZoom.didChange, object: nil, queue: .main) { [weak self] _ in
                guard let self, let textView = self.textView else { return }
                textView.applyTypeScale()
                self.updateHeight()
            }
        }

        deinit {
            if let widthObserver { NotificationCenter.default.removeObserver(widthObserver) }
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
        }

        /// A narrower window wraps the text onto more lines, so the box
        /// re-measures when its width changes (and only then).
        func watchWidth(of scroll: NSScrollView) {
            scroll.postsFrameChangedNotifications = true
            widthObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, abs(scroll.frame.width - self.lastWidth) > 0.5 else { return }
                self.lastWidth = scroll.frame.width
                self.updateHeight()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView else { return }
            let height = ComposerTextField.fittingHeight(of: textView)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onReturnWhenEmpty: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onImages: (([URL]) -> Void)?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    /// Builds its own TextKit 1 stack. `init(frame:textContainer: nil)` makes
    /// a text view with no text storage at all, which silently drops every
    /// keystroke (the review found nobody could type a message).
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A draft from another thread, or the box emptied after a send.
    /// Setting `string` doesn't reliably take the typing attributes, so the
    /// font and line spacing are put back on the whole text.
    func replaceText(_ text: String) {
        string = text
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(ComposerTextField.attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// The font and line height at the current zoom, for what's typed
    /// next and (after a zoom change) what's already in the box.
    func applyTypeScale() {
        let attributes = ComposerTextField.attributes
        font = ComposerTextField.font
        defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertLineContinuingList()
            } else if string.isEmpty, onReturnWhenEmpty?() == true {
                // Allowed the waiting approval.
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// A new line that carries on a markdown list ("2. " after "1. foo"),
    /// or ends it from an empty item. Through `insertText`, so it's one undo.
    private func insertLineContinuingList() {
        guard let edit = ListContinuation.newline(in: string, selection: selectedRange()) else {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        insertText(edit.text, replacementRange: edit.range)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if takeImages(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasImages(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func imageURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    private func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        !imageURLs(pasteboard).isEmpty || pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    /// Image files go straight to `media.import`; raw image data (a
    /// screenshot on the clipboard) is written to a temp PNG first.
    func takeImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = imageURLs(pasteboard)
        if !urls.isEmpty {
            onImages?(urls)
            return true
        }
        // Text with an image flavour (rich text from a browser) stays text.
        if pasteboard.string(forType: .string) != nil { return false }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        let png: Data?
        if pasteboard.data(forType: .png) != nil {
            png = data
        } else {
            png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }
        guard let png else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("threadbear-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            onImages?([url])
            return true
        } catch {
            return false
        }
    }

    /// Mid grey on the dark card, like Codex's and Claude's: the system
    /// placeholder colour there was about 2.3:1, the dimmest of the four
    /// apps. Light mode keeps the system colour.
    static let placeholderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.45) : .placeholderTextColor
    }

    /// The placeholder is drawn outside the glyphs, so the first character
    /// typed (or the last one deleted) has to redraw the whole box.
    private var wasEmpty = true

    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty != wasEmpty {
            wasEmpty = string.isEmpty
            needsDisplay = true
        }
    }

    override var string: String {
        didSet {
            wasEmpty = string.isEmpty
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            var attributes = ComposerTextField.attributes
            attributes[.foregroundColor] = Self.placeholderColor
            // Where the first character would go, on the same line height
            // and baseline, so typing doesn't shift it.
            let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
            let rect = NSRect(x: x, y: textContainerInset.height, width: max(0, bounds.width - x), height: ComposerTextField.lineHeight)
            NSAttributedString(string: placeholder, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin])
        }
    }
}
