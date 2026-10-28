import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

extension AppModel {
    /// Opens a review in the dock's Review panel, a tab beside its thread,
    /// or brings up the window it was popped out into.
    func openReview(threadId: String, review: DesignReview) {
        let key = threadId + "/" + review.id
        if let existing = reviewWindows[key] {
            existing.session.receive(review)
            existing.present()
            return
        }
        // The review is a tab beside the main panel, so the main panel
        // moves to its thread first: that closes another thread's review
        // still there (mainContextChanged), and must come before this one
        // is set up. One dragged out elsewhere is replaced in place.
        if selection != threadId { select(threadId) }
        if let session = reviewPanel, session.threadId == threadId, session.review.id == review.id {
            session.receive(review)
        } else {
            if let old = reviewPanel { Task { await old.saveNow() } }
            reviewPanel = makeReviewSession(threadId: threadId, review: review)
        }
        showReviewPanel(threadId: threadId)
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
        let threadId = session.threadId
        let key = threadId + "/" + session.review.id
        dock.close(WindowDock.review)
        reviewPanel = nil
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
                Label("Review design options (\(thread.pendingReviews ?? 0))", systemImage: "rectangle.on.rectangle")
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
        let window = ReviewNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.reviewSession = session
        window.title = session.review.title
        window.subtitle = threadTitle
        window.minSize = NSSize(width: 780, height: 650)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("DesignReview")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReviewWindow(session: session, back: back, close: { [weak self] in self?.close() }))
        window.center()
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
        if !(firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 123 { reviewSession?.browse(-1); return }
            if event.keyCode == 124 { reviewSession?.browse(1); return }
            if event.keyCode == 36, let session = reviewSession {
                session.mode = session.mode == .single ? .pair : .single
                return
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

/// The review: the images, a pick and notes on each, and Send. Shown in the
/// dock's Review panel, or in a window of its own when popped out.
struct ReviewWindow: View {
    @Bindable var session: ReviewSession
    var inPanel = false
    let back: () -> Void
    let close: () -> Void
    @State private var confirmingCancel = false
    @State private var noteExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let note = session.review.note, !note.isEmpty {
                Text(note).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
                    .lineLimit(noteExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { noteExpanded.toggle() }
                    .tip(noteExpanded ? "Click to shorten" : "Click to read it all")
            }
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
                canvases
                if session.mode != .grid && session.review.options.count > session.visibleIndices.count { strip }
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onMoveCommand { direction in
            if direction == .left { session.browse(-1) }
            if direction == .right { session.browse(1) }
        }
        .confirmationDialog("Cancel this review?", isPresented: $confirmingCancel) {
            Button("Cancel review", role: .destructive) { Task { await session.cancelReview() } }
        } message: { Text("The agent won’t get a reply. You can still look at the images.") }
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $session.mode) {
                Image(systemName: "square.grid.2x2").tag(ReviewMode.grid)
                Image(systemName: "rectangle.split.2x1").tag(ReviewMode.pair)
                Image(systemName: "rectangle").tag(ReviewMode.single)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .tip("All of them, two side by side, or one at a time (← → to move)")
            Spacer(minLength: 10)
            Toggle(isOn: $session.actualSize) {
                Image(systemName: session.actualSize ? "minus.magnifyingglass" : "plus.magnifyingglass")
            }.toggleStyle(.button)
                .tip(session.actualSize ? "Fit each image in its space" : "Show at full size and scroll")
            if !inPanel {
                Button { back() } label: { Image(systemName: "arrow.up.backward") }
                    .tip("Show the thread this came from")
            }
        }.font(.system(size: TypeScale.work)).padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var canvases: some View {
        if session.mode == .grid {
            GeometryReader { geo in
                let columns = geo.size.width < 620 ? 1 : 2
                let rows = max(1, Int(ceil(Double(session.review.options.count) / Double(columns))))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(session.visibleIndices, id: \.self) { index in
                            option(index, slot: 0, grid: true)
                                .frame(height: max(220, (geo.size.height - 12 * CGFloat(min(rows, 2) - 1)) / CGFloat(min(rows, 2))))
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 6)
                }
            }
        } else {
            HStack(spacing: 12) {
                ForEach(Array(session.visibleIndices.enumerated()), id: \.element) { slot, index in
                    option(index, slot: slot, grid: false)
                }
            }.padding(.horizontal, 14)
        }
    }

    private func option(_ index: Int, slot: Int, grid: Bool) -> some View {
        let option = session.review.options[index]
        let picked = session.draft.pickedId == option.id
        let hasNotes = session.draft.notes[option.id]?.isEmpty == false
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if grid || session.review.options.count < 2 {
                    Text(option.label).fontWeight(.medium).lineLimit(1)
                        .tip(option.note ?? option.label)
                } else {
                    Picker("Image", selection: Binding(get: { index }, set: { session.show($0, slot: slot) })) {
                        ForEach(Array(session.review.options.enumerated()), id: \.element.id) { i, item in
                            Text(item.label).tag(i)
                        }
                    }.labelsHidden().frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                        .tip("Which one to show here")
                }
                Spacer(minLength: 4)
                if grid && hasNotes {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        .tip(session.draft.notes[option.id] ?? "")
                }
                if option.reference {
                    Text("Reference").foregroundStyle(.secondary).font(.system(size: TypeScale.detail))
                        .tip("Shown for context. It isn't one of the choices.")
                } else {
                    Button {
                        session.pick(option.id)
                    } label: {
                        Label(picked ? "Picked" : "Pick", systemImage: picked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked ? Color.accentColor : Color.primary)
                    }.disabled(!session.editable)
                        .tip(picked ? "Click again to unpick" : "Pick this one")
                }
            }.font(.system(size: TypeScale.work)).padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ZStack {
                ReviewCanvas(image: option.image, actualSize: session.actualSize)
                if grid {
                    // In the grid, a click opens the image on its own, with
                    // room for notes.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture {
                            session.show(index, slot: 0)
                            session.mode = .single
                        }
                        .tip("Click to open it on its own and add notes")
                }
            }
            // minWidth 0: the image view's own size mustn't push two cards
            // wider than a narrow panel.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(option.label). Scroll to inspect the image.")
            if !grid {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let note = option.note { Text(note).foregroundStyle(.secondary).lineLimit(2) }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(get: { session.draft.notes[option.id] ?? "" }, set: { session.setNote($0, for: option.id) }))
                            .font(.system(size: TypeScale.work)).scrollContentBackground(.hidden)
                            .disabled(!session.editable)
                            .accessibilityLabel("Notes on \(option.label)")
                        if !hasNotes {
                            Text(session.editable ? "Notes for the agent" : "No notes")
                                .font(.system(size: TypeScale.work)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(6).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(height: 64)
                }.font(.system(size: TypeScale.detail)).padding(10)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor), lineWidth: picked ? 1.5 : 1))
    }

    /// Thumbnails to step through the others in 2-up and single.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(session.review.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        session.show(index, slot: session.mode == .pair ? 1 : 0)
                    } label: {
                        ReviewCanvas(image: option.image, actualSize: false).frame(width: 64, height: 42).allowsHitTesting(false)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                session.draft.pickedId == option.id ? Color.accentColor : session.visibleIndices.contains(index) ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                                lineWidth: session.visibleIndices.contains(index) || session.draft.pickedId == option.id ? 1.5 : 0.5))
                            .overlay(alignment: .topLeading) {
                                Text(option.id).font(.system(size: TypeScale.small, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3)).padding(3)
                            }
                    }.buttonStyle(.plain)
                        .tip(option.label)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(status).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary).lineLimit(1)
                .tip(session.review.isPending ? (session.saving ? "Saving your draft" : "Your draft is kept. Nothing's sent until you press Send.") : "You can come back to these any time")
            Spacer()
            if session.review.isPending {
                Menu {
                    Button("Cancel review", role: .destructive) { confirmingCancel = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .tip("More")
                Button("Later") { close() }.disabled(session.submitting)
                    .tip("Close it. Your draft is kept.")
                Button(session.submitting ? "Sending…" : "Send") {
                    Task {
                        await session.submit()
                        // Once it's sent there's nothing left to do here, so
                        // it gets out of the way (Mike, 28 Oct). A failed send
                        // stays open with its error and the notes kept.
                        if session.review.status == "answered" { close() }
                    }
                }
                    .buttonStyle(.borderedProminent).disabled(!session.canSubmit)
                    .tip("Send your pick and notes to the agent")
            } else {
                Button("Done") { close() }
                    .tip("Close it")
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
    }

    private var status: String {
        if session.review.status == "cancelled" { return "Cancelled" }
        if !session.review.isPending && session.review.status != "answered" { return "Closed" }
        let shown = session.review.isPending ? session.draft : (session.review.response ?? session.draft)
        let picked = session.review.options.first { $0.id == shown.pickedId }
        let notes = shown.notes.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        var parts: [String] = []
        if session.review.status == "answered" { parts.append("Sent") }
        if let picked { parts.append("Picked \(picked.label)") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        if parts.isEmpty { return session.review.isPending ? (session.saving ? "Saving…" : "Pick one, or leave notes") : "Sent" }
        return parts.joined(separator: " · ")
    }
}

/// Each canvas has its own native scroll view. Fit keeps the entire image
/// visible, including the shorter reference image. 100% preserves source
/// pixels and enables independent panning without stretching either image.
private struct ReviewCanvas: NSViewRepresentable {
    let image: ImageRef
    let actualSize: Bool
    func makeNSView(context: Context) -> ReviewImageScroll { ReviewImageScroll() }
    func updateNSView(_ view: ReviewImageScroll, context: Context) { view.show(image, actual: actualSize) }
}

private final class ReviewImageScroll: NSScrollView {
    private let picture = NSImageView()
    private var reference: ImageRef?
    private var actual = false
    private var loadedKey = ""
    private var resetScroll = true
    private var orientedSize: NSSize?

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
