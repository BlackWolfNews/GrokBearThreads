import AppKit
import SwiftUI
import ThreadbareCore
import UniformTypeIdentifiers

/// The message box at the bottom: Return sends, Shift-Return adds a line,
/// paste or drop images, Stop while running, and small menus for folder,
/// account, model and "Ask before edits".
struct ComposerView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary?
    @State private var height: CGFloat = 22
    @State private var importing = 0

    private var draftKey: String { thread?.id ?? "new" }

    var body: some View {
        let draft = Binding<Draft>(
            get: { app.drafts[draftKey] ?? Draft() },
            set: { app.drafts[draftKey] = $0 }
        )
        let running = thread?.status.isBusy == true
        VStack(alignment: .leading, spacing: 6) {
            if !draft.wrappedValue.images.isEmpty || importing > 0 {
                AttachmentStrip(images: draft.images, importing: importing)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextField(
                    text: draft.text,
                    height: $height,
                    focusTrigger: app.focusComposer,
                    placeholder: thread == nil ? "Start a new thread" : "Message",
                    onSend: { send(draft) },
                    onImages: { urls in attach(urls, to: draft) }
                )
                .frame(height: min(180, max(22, height)))
                if running {
                    Button {
                        app.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        send(draft)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .help("Send (Return)")
                    .disabled(draft.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.wrappedValue.images.isEmpty)
                }
            }
            ComposerControls(thread: thread)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: Theme.maxContentWidth + 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private func send(_ draft: Binding<Draft>) {
        // AppModel empties the box, and puts the draft back if it isn't sent.
        app.send(threadId: thread?.id)
    }

    private func attach(_ urls: [URL], to draft: Binding<Draft>) {
        importing += urls.count
        Task {
            let refs = await app.importImages(urls)
            importing -= urls.count
            draft.wrappedValue.images += refs
        }
    }
}

private struct AttachmentStrip: View {
    @Binding var images: [ImageRef]
    let importing: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                ZStack(alignment: .topTrailing) {
                    AsyncThumbnail(path: image.path)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        images.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                    .help("Remove")
                }
            }
            if importing > 0 {
                ProgressView().controlSize(.small)
            }
        }
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
                Rectangle().fill(.quaternary)
            }
        }
        .onAppear {
            ThumbnailLoader.shared.load(path: path, maxPixels: 104) { image = $0 }
        }
    }
}

private struct ComposerControls: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary?

    var body: some View {
        let cwd = thread?.cwd ?? app.newThreadCwd ?? app.defaults.cwd
        let account = thread?.accountId ?? app.newThreadAccount ?? app.lastAccountId
        let model = thread == nil ? app.newThreadModel : thread?.model
        let ask = thread.map { $0.permissionMode == .ask } ?? app.newThreadAsk
        HStack(spacing: 12) {
            Menu {
                ForEach(recentFolders(including: cwd), id: \.self) { folder in
                    Button(folder.abbreviatingHome) { setCwd(folder) }
                }
                Divider()
                Button("Choose…") { chooseFolder() }
            } label: {
                Label(cwd.abbreviatingHome, systemImage: "folder")
            }
            Menu {
                ForEach(app.accounts) { item in
                    Button(item.title) { setAccount(item.id) }
                }
            } label: {
                Label(app.accountTitle(account), systemImage: "person.crop.circle")
            }
            Menu {
                Button("Account default") { setModel(nil) }
                Divider()
                ForEach(["opus", "sonnet", "haiku"], id: \.self) { name in
                    Button(name.capitalized) { setModel(name) }
                }
            } label: {
                Label(model.map(ModelName.display) ?? "Default model", systemImage: "cpu")
            }
            Toggle("Ask before edits", isOn: Binding(get: { ask }, set: { setAsk($0) }))
                .toggleStyle(.checkbox)
            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }

    private func recentFolders(including cwd: String) -> [String] {
        var seen = Set<String>()
        var folders: [String] = []
        for folder in [cwd, app.defaults.cwd] + app.threads.values.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }).map(\.cwd) {
            guard !folder.isEmpty, seen.insert(folder).inserted else { continue }
            folders.append(folder)
            if folders.count >= 8 { break }
        }
        return folders
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { setCwd(url.path) }
    }

    private func setCwd(_ folder: String) {
        if let thread { app.setCwd(thread.id, folder) } else { app.newThreadCwd = folder }
    }

    private func setAccount(_ id: String) {
        if let thread { app.setAccount(thread.id, id) } else { app.newThreadAccount = id }
    }

    private func setModel(_ model: String?) {
        if let thread { app.setModel(thread.id, model) } else { app.newThreadModel = model }
    }

    private func setAsk(_ ask: Bool) {
        if let thread { app.setPermission(thread.id, ask: ask) } else { app.newThreadAsk = ask }
    }
}

/// NSTextView-backed field that grows with its text.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusTrigger: Int
    var placeholder: String
    var onSend: () -> Void
    var onImages: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        textView.onSend = onSend
        textView.onImages = onImages
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
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

        init(_ parent: ComposerTextField) {
            self.parent = parent
            lastFocus = parent.focusTrigger
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height) + 4
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onImages: (([URL]) -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
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

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("threadbare-paste", isDirectory: true)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
            NSAttributedString(string: placeholder, attributes: attributes).draw(at: NSPoint(x: 4, y: textContainerInset.height))
        }
    }
}
