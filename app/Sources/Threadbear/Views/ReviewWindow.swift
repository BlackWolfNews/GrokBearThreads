import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

extension AppModel {
    /// Opens a review in a window of its own, most of the screen (Mike,
    /// 30 Oct): beside the thread as a dock tab the images were too small
    /// to compare. A review already in the Review panel moves out of it,
    /// keeping its draft.
    func openReview(threadId: String, review: DesignReview) {
        let key = threadId + "/" + review.id
        if let existing = reviewWindows[key] {
            existing.session.receive(review)
            existing.present()
            return
        }
        if let session = reviewPanel, session.threadId == threadId, session.review.id == review.id {
            session.receive(review)
            popOutReview()
            return
        }
        presentReviewWindow(makeReviewSession(threadId: threadId, review: review))
    }

    private func makeReviewSession(threadId: String, review: DesignReview) -> ReviewSession {
        // Resolve the client for each call: a review can stay open through
        // a runner handover and must not keep the disconnected client.
        func connected() throws -> RPCClient {
            guard let client else { throw NSError(domain: "Threadbear", code: 1, userInfo: [NSLocalizedDescriptionKey: "The runner is disconnected."]) }
            return client
        }
        let service = ReviewService(
            load: { try await connected().review(threadId: threadId, reviewId: review.id) },
            save: { revision, draft in try await connected().saveReview(threadId: threadId, reviewId: review.id, revision: revision, draft: draft) },
            respond: { revision, draft in try await connected().respondReview(threadId: threadId, reviewId: review.id, revision: revision, draft: draft).review },
            cancel: { revision in try await connected().cancelReview(threadId: threadId, reviewId: review.id, revision: revision) }
        )
        return ReviewSession(threadId: threadId, review: review, service: service)
    }

    /// A tab in the main panel's group (Mike, 28 Oct), or in the group of
    /// its thread's own panel if it has one, unless it's open already,
    /// wherever that is.
    private func showReviewPanel(threadId: String) {
        let panel = WindowDock.review
        if dock.layout.contains(panel) {
            dock.show(panel)
        } else if let group = dock.layout.group(containing: WindowDock.threadPanel(threadId)) {
            dock.open(panel, .tab(group: group.id))
        } else {
            openMainTab(panel)
        }
    }

    func closeReviewPanel() {
        if let session = reviewPanel { Task { await session.saveNow() } }
        dock.close(WindowDock.review)
        reviewPanel = nil
    }

    /// Moves the panel's review into a window of its own, for full screen
    /// or a second display. The same session, so nothing typed is lost.
    func popOutReview() {
        guard let session = reviewPanel else { return }
        dock.close(WindowDock.review)
        reviewPanel = nil
        presentReviewWindow(session)
    }

    private func presentReviewWindow(_ session: ReviewSession) {
        let threadId = session.threadId
        let key = threadId + "/" + session.review.id
        let controller = ReviewWindowController(session: session, threadTitle: threads[threadId]?.title ?? "Thread", back: { [weak self] in
            self?.select(threadId)
            #if DEBUG
            if Automation.instanceId != nil { return }
            #endif
            NSApp.windows.first { $0.isVisible && !($0 is ReviewNativeWindow) && !($0 is DockPanelWindow) && $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
        })
        controller.onClose = { [weak self] in self?.reviewWindows.removeValue(forKey: key) }
        reviewWindows[key] = controller
        controller.present()
    }

    func receiveReview(_ review: DesignReview, threadId: String) {
        reviewWindows[threadId + "/" + review.id]?.session.receive(review)
        if let session = reviewPanel, session.threadId == threadId, session.review.id == review.id { session.receive(review) }
    }
}

/// The Review panel's bar: pop it out into a window.
struct ReviewPanelButtons: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PaneHeaderButton(symbol: "macwindow.on.rectangle", help: "Open in its own window") { app.popOutReview() }
    }
}

/// A pending request can be older than the loaded transcript page. The
/// runner's list keeps it one click away without fetching the whole thread.
struct PendingReviewsButton: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    @State private var showing = false
    @State private var reviews: [DesignReview] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        HStack {
            Button {
                showing = true
            } label: {
                Label("Review design options (\(thread.pendingReviews ?? 0))", systemImage: Symbols.review)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .tip("Compare the images the agent made side by side, and reply")
            Spacer()
        }
        .font(.system(size: TypeScale.work)).padding(.horizontal, 20).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(reviews) { review in
                    Button {
                        showing = false
                        app.openReview(threadId: thread.id, review: review)
                    } label: {
                        HStack {
                            Text(review.title)
                            Spacer(minLength: 18)
                            Text("\(review.options.count) images").foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .tip("Open this review")
                }
                if !loading && reviews.isEmpty && error == nil { Text("No reviews waiting.").foregroundStyle(.secondary) }
            }.font(.system(size: TypeScale.work)).padding(16).frame(minWidth: 300)
                .task {
                    loading = true
                    error = nil
                    defer { loading = false }
                    do {
                        guard let client = app.client else { throw NSError(domain: "Threadbear", code: 1, userInfo: [NSLocalizedDescriptionKey: "The runner is disconnected."]) }
                        reviews = try await client.pendingReviews(threadId: thread.id)
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
}

@MainActor
final class ReviewWindowController: NSWindowController, NSWindowDelegate {
    let session: ReviewSession
    var onClose: (() -> Void)?

    init(session: ReviewSession, threadTitle: String, back: @escaping () -> Void) {
        self.session = session
        // On the screen Threadbear's in, not wherever the mouse is.
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let frame = Self.frame(on: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1240 / 0.9, height: 860 / 0.9))
        let window = ReviewNativeWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.reviewSession = session
        window.title = session.review.title
        window.subtitle = threadTitle
        window.minSize = NSSize(width: 780, height: 650)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        // No frame autosave: each review opens at the size below, not
        // whatever the last one was dragged to.
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReviewWindow(session: session, back: back, close: { [weak self] in self?.close() }))
        // Up in the title bar rather than a row of their own, so the images
        // and the choices get that height. Wide enough for all of them, as an
        // accessory doesn't resize when some come and go.
        let buttons = NSHostingView(rootView: ReviewTitlebarButtons(session: session, back: back))
        buttons.frame.size = NSSize(width: 130, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = buttons
        window.addTitlebarAccessoryViewController(accessory)
        window.setFrame(frame, display: false)
    }

    /// 90% of the screen, centred, so a border of the desktop shows round
    /// it; capped on a huge display, where 90% would be a wall of image.
    static let maxSize = NSSize(width: 2400, height: 1500)

    static func frame(on visible: NSRect) -> NSRect {
        let width = min(visible.width * 0.9, maxSize.width)
        let height = min(visible.height * 0.9, maxSize.height)
        return NSRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width.rounded(), height: height.rounded())
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        #if DEBUG
        if Automation.instanceId != nil {
            window?.tuckBehind()
            return
        }
        #endif
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keystrokes are already cached locally. Try to flush the final
        // debounce too; a failed connection still leaves that local copy.
        Task { [session] in await session.saveNow() }
        onClose?()
    }
}

private final class ReviewNativeWindow: NSWindow {
    weak var reviewSession: ReviewSession?

    override func keyDown(with event: NSEvent) {
        // Text editors own their arrows and Return. Outside an editor,
        // browsing works immediately without first clicking the canvas.
        if !(firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let session = reviewSession {
            switch event.keyCode {
            case 123, 126: session.browse(-1); return // left, up
            case 124, 125: session.browse(1); return // right, down
            case 36: // Return
                if session.mode == .single { session.showAll() } else { session.browse(0) }
                return
            case 53 where session.mode == .single: // Esc
                session.showAll()
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

extension ReviewOption {
    /// Agents often number their titles already ("1. One decision at a
    /// time"); don't say the number twice.
    var label: String {
        title.hasPrefix(id + ".") || title.hasPrefix(id + " ") || title == id ? title : "\(id). \(title)"
    }
}

/// The buttons in a review window's title bar.
private struct ReviewTitlebarButtons: View {
    @Bindable var session: ReviewSession
    let back: () -> Void
    @State private var confirmingCancel = false

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if session.mode == .single {
                icon("square.grid.2x2", "See them all (Esc)") { session.showAll() }
                icon(session.actualSize ? "minus.magnifyingglass" : "plus.magnifyingglass",
                     session.actualSize ? "Fit the image in its space" : "Show at full size and scroll") { session.actualSize.toggle() }
            }
            icon("arrow.up.backward", "Show the thread this came from", back)
            if session.review.isPending {
                Menu {
                    Button("Cancel review", role: .destructive) { confirmingCancel = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26)
                    .tip("More")
            }
        }
        .padding(.trailing, 10)
        .foregroundStyle(.secondary)
        .confirmationDialog("Cancel this review?", isPresented: $confirmingCancel) {
            Button("Cancel review", role: .destructive) { Task { await session.cancelReview() } }
        } message: { Text("The agent won\u{2019}t get a reply. You can still look at the images.") }
    }

    private func icon(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).tip(tip)
    }
}

/// The review: every image on the stage, and on the right the question, the
/// choices with the agent's reasons, a note on any of them, and Send. Mike
/// picked this layout on 1 Nov, over the grid of cards that hid the notes and
/// reasons and put Pick and Send at opposite ends of the window.
struct ReviewWindow: View {
    @Bindable var session: ReviewSession
    var inPanel = false
    let back: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// Choices with a box because the note icon was pressed. A pick or a
    /// saved note opens one by itself.
    @State private var openedNotes: Set<String> = []
    @FocusState private var typingIn: String?

    private static let railWidth: CGFloat = 340
    private static let stageInset: CGFloat = 14
    private static let cellSpacing: CGFloat = 12
    private static let cellPadding: CGFloat = 8
    private static let captionHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error {
                HStack {
                    Text(error).font(.system(size: TypeScale.detail)).textSelection(.enabled)
                    Spacer()
                    if session.conflict && session.review.isPending {
                        Button("Save my draft") { Task { await session.keepMyDraft() } }
                            .tip("Keep what you have here, over the copy that changed elsewhere")
                    } else if session.review.isPending {
                        Button("Try saving again") { Task { await session.saveNow() } }
                            .tip("Save the draft to the runner again")
                    }
                }.padding(12).background(Color.orange.opacity(0.1))
            }
            if session.review.options.isEmpty {
                ContentUnavailableView("No images to compare", systemImage: "photo")
            } else {
                HStack(spacing: 0) {
                    stage
                    Divider()
                    rail.frame(width: Self.railWidth)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await session.refresh()
            // Keeps up with replies from elsewhere (the phone, a second
            // window) while the thread's transcript isn't subscribed.
            while !Task.isCancelled && session.review.isPending {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await session.refresh()
            }
        }
    }

    // MARK: The images

    private var stage: some View {
        GeometryReader { geo in
            let room = CGSize(width: max(0, geo.size.width - Self.stageInset * 2), height: max(0, geo.size.height - Self.stageInset * 2))
            Group {
                if session.mode == .single, session.review.options.indices.contains(session.focused) {
                    cell(session.focused, size: room)
                } else {
                    let layout = ReviewGalleryLayout.best(
                        aspects: session.review.options.map(aspect), width: room.width, height: room.height, spacing: Self.cellSpacing,
                        chromeWidth: Self.cellPadding * 2, chromeHeight: Self.cellPadding * 2 + Self.captionHeight)
                    let indices = Array(session.review.options.indices)
                    VStack(spacing: Self.cellSpacing) {
                        ForEach(Array(stride(from: 0, to: indices.count, by: layout.columns)), id: \.self) { first in
                            HStack(spacing: Self.cellSpacing) {
                                ForEach(first..<min(first + layout.columns, indices.count), id: \.self) { index in
                                    cell(index, size: CGSize(width: layout.cellWidth, height: layout.cellHeight))
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // minWidth 0: the image view's own size mustn't push the rail away.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
    }

    private func aspect(_ option: ReviewOption) -> Double {
        guard let width = option.image.width, let height = option.image.height, width > 0, height > 0 else { return 1100.0 / 760.0 }
        return Double(width) / Double(height)
    }

    private func cell(_ index: Int, size: CGSize) -> some View {
        let option = session.review.options[index]
        let picked = session.draft.pickedId == option.id
        let enlarged = session.mode == .single
        let scrolling = enlarged && session.actualSize
        let room = CGSize(width: max(0, size.width - Self.cellPadding * 2), height: max(0, size.height - Self.cellPadding * 2 - Self.captionHeight))
        let fit = ReviewGalleryLayout.fit(aspect: aspect(option), width: room.width, height: room.height)
        return VStack(alignment: .leading, spacing: 0) {
            Text(option.id)
                .font(.system(size: TypeScale.detail, weight: .semibold))
                .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                .lineLimit(1).frame(height: Self.captionHeight, alignment: .topLeading)
            // At full size a click is for scrolling, so it does nothing.
            ReviewCanvas(image: option.image, actualSize: scrolling, onClick: scrolling ? nil : {
                if enlarged { session.showAll() } else { session.enlarge(index) }
            })
            .tip(scrolling ? "" : "\(option.id): click to \(enlarged ? "see them all" : "enlarge")")
            .frame(width: scrolling ? room.width : fit.width, height: scrolling ? room.height : fit.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(option.label). Scroll to inspect the image.")
        }
        .padding(Self.cellPadding)
        .frame(width: size.width, height: size.height)
        .overlay {
            if picked {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    // MARK: The answer

    private var rail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = session.review.note, !note.isEmpty {
                        Text(note).font(.system(size: TypeScale.work)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .padding(14)
                        Divider()
                    }
                    ForEach(Array(session.review.options.enumerated()), id: \.element.id) { index, option in
                        choice(option, index: index)
                        Divider()
                    }
                }
            }
            Divider()
            footer.padding(14)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func choice(_ option: ReviewOption, index: Int) -> some View {
        let picked = session.draft.pickedId == option.id
        let note = session.draft.notes[option.id] ?? ""
        let hasNote = !note.isEmpty
        let showsBox = session.editable && (picked || hasNote || openedNotes.contains(option.id))
        let enlarged = session.mode == .single && session.focused == index
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if session.editable && !option.reference {
                    Button { choose(option, index: index) } label: { choiceText(option, picked: picked) }
                        .buttonStyle(.plain)
                        .tip(picked ? "Unpick \(option.id)" : "Pick \(option.id)")
                } else {
                    choiceText(option, picked: picked)
                }
                if session.editable && !showsBox {
                    Button {
                        openedNotes.insert(option.id)
                        focusSoon(option.id)
                    } label: {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 24, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Add a note on \(option.label)")
                        .tip("Add a note on \(option.id)")
                }
            }
            if showsBox {
                noteBox(option, note: note).padding(.leading, 25)
            } else if !session.editable && hasNote {
                Text(note).font(.system(size: TypeScale.work)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 25)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Color.accentColor.opacity(0.1) : enlarged ? Color.primary.opacity(0.05) : Color.clear)
    }

    private func choiceText(_ option: ReviewOption, picked: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // A reference has no pick, and neither has a sent review's other
            // choices; the gap keeps the text lined up all the same.
            Group {
                if picked {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                } else if session.editable && !option.reference {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label).font(.system(size: TypeScale.work, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = option.note, !reason.isEmpty {
                    Text(reason).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func noteBox(_ option: ReviewOption, note: String) -> some View {
        ZStack(alignment: .topLeading) {
            // Grows with what's typed: the hidden copy sets the height.
            Text(note + "\n").font(.system(size: TypeScale.work)).opacity(0)
                .padding(.horizontal, 5).padding(.vertical, 1)
            TextEditor(text: Binding(get: { session.draft.notes[option.id] ?? "" }, set: { session.setNote($0, for: option.id) }))
                .font(.system(size: TypeScale.work)).scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($typingIn, equals: option.id)
                .accessibilityLabel("Note on \(option.label)")
            if note.isEmpty {
                Text("Add a note").font(.system(size: TypeScale.work)).foregroundStyle(.tertiary)
                    .padding(.leading, 5).allowsHitTesting(false)
            }
        }
        .frame(minHeight: 60, maxHeight: 220)
        .padding(6)
        .background(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(typingIn == option.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// A pick goes straight to its note box, so adding detail is just typing.
    private func choose(_ option: ReviewOption, index: Int) {
        let picking = session.draft.pickedId != option.id
        session.pick(option.id)
        if session.mode == .single { session.enlarge(index) }
        if picking { focusSoon(option.id) } else if typingIn == option.id { typingIn = nil }
    }

    /// The box only exists from the next update.
    private func focusSoon(_ id: String) {
        Task { @MainActor in typingIn = id }
    }

    @ViewBuilder private var footer: some View {
        if session.review.isPending {
            Button {
                Task {
                    await session.submit()
                    // Once it's sent there's nothing left to do here, so
                    // it gets out of the way (Mike, 28 Oct). A failed send
                    // stays open with its error and the notes kept.
                    if session.review.status == "answered" { close() }
                }
            } label: {
                Text(session.sendLabel).fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!session.canSubmit)
            .tip("Send your pick and notes to the agent (\u{2318}\u{21A9}). Close the window to finish it later.")
        } else {
            HStack {
                Text(status).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { close() }.tip("Close it")
            }
        }
    }

    /// Only for a review that's over, as one that's waiting says it on Send.
    private var status: String {
        switch session.review.status {
        case "answered": return "Sent"
        case "cancelled": return "Cancelled"
        case "superseded": return "Answered in the thread"
        default: return "Closed"
        }
    }
}

/// Each canvas has its own native scroll view. Fit keeps the entire image
/// visible, including the shorter reference image. 100% preserves source
/// pixels and enables independent panning without stretching either image.
private struct ReviewCanvas: NSViewRepresentable {
    let image: ImageRef
    let actualSize: Bool
    let onClick: (() -> Void)?
    func makeNSView(context: Context) -> ReviewImageScroll { ReviewImageScroll() }
    func updateNSView(_ view: ReviewImageScroll, context: Context) {
        view.onClick = onClick
        view.show(image, actual: actualSize)
    }
}

private final class ReviewImageScroll: NSScrollView {
    private let picture = NSImageView()
    private var reference: ImageRef?
    private var actual = false
    private var loadedKey = ""
    private var resetScroll = true
    private var orientedSize: NSSize?
    /// Taken here rather than by a SwiftUI gesture on top: SwiftUI doesn't
    /// hand it a click over an AppKit view (ReviewWindowTests caught it).
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    // The first click counts even if the window wasn't in front, like a
    // SwiftUI button beside it does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        documentView = picture
    }
    required init?(coder: NSCoder) { fatalError() }

    // Takes whatever room SwiftUI gives it, never the image's size.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func show(_ image: ImageRef, actual: Bool) {
        if reference?.path != image.path { picture.image = nil; loadedKey = ""; resetScroll = true; orientedSize = nil }
        if self.actual != actual { resetScroll = true }
        reference = image
        self.actual = actual
        picture.imageScaling = actual ? .scaleNone : .scaleProportionallyUpOrDown
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let reference, contentSize.width > 0, contentSize.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let source = orientedSize ?? NSSize(width: reference.width ?? 1100, height: reference.height ?? 760)
        let size: NSSize
        if actual {
            size = NSSize(width: max(contentSize.width, source.width / scale), height: max(contentSize.height, source.height / scale))
        } else { size = contentSize }
        picture.frame = NSRect(origin: .zero, size: size)
        if resetScroll {
            // NSImageView uses AppKit's bottom-left origin. Start at the
            // image's top edge when zooming in, rather than its footer.
            contentView.scroll(to: NSPoint(x: 0, y: max(0, size.height - contentSize.height)))
            reflectScrolledClipView(contentView)
            resetScroll = false
        }
        let desired = actual ? max(source.width, source.height) : max(contentSize.width, contentSize.height) * scale
        let pixels = min(10000, max(128, Int(ceil(desired / 256)) * 256))
        let key = reference.path + "|\(pixels)"
        guard loadedKey != key else { return }
        loadedKey = key
        ThumbnailLoader.shared.load(path: reference.path, maxPixels: pixels) { [weak self] cg in
            guard let self, self.loadedKey == key else { return }
            guard let cg else {
                self.picture.setTip("Couldn’t load this image. The saved file may be missing.")
                self.picture.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "Image unavailable")
                return
            }
            self.picture.setTip("")
            // ImageIO applied EXIF orientation while decoding. Preserve its
            // ratio instead of assigning the file header's unrotated size.
            let ratio = max(source.width, source.height) / CGFloat(max(cg.width, cg.height))
            let oriented = NSSize(width: CGFloat(cg.width) * ratio, height: CGFloat(cg.height) * ratio)
            if self.orientedSize != oriented {
                self.orientedSize = oriented
                self.resetScroll = true
                self.needsLayout = true
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: oriented.width / scale, height: oriented.height / scale))
            self.picture.image = image
        }
    }
}
