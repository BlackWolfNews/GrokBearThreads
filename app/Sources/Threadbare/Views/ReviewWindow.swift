import AppKit
import SwiftUI
import ThreadbareCore

extension AppModel {
    func openReview(threadId: String, review: DesignReview) {
        let key = threadId + "/" + review.id
        if let existing = reviewWindows[key] {
            existing.session.receive(review)
            existing.present()
            return
        }
        // Resolve the client for each call: a window can stay open through
        // a runner handover and must not keep the disconnected client.
        func connected() throws -> RPCClient {
            guard let client else { throw NSError(domain: "Threadbare", code: 1, userInfo: [NSLocalizedDescriptionKey: "The runner is disconnected."]) }
            return client
        }
        let service = ReviewService(
            load: { try await connected().review(threadId: threadId, reviewId: review.id) },
            save: { revision, draft in try await connected().saveReview(threadId: threadId, reviewId: review.id, revision: revision, draft: draft) },
            respond: { revision, draft in try await connected().respondReview(threadId: threadId, reviewId: review.id, revision: revision, draft: draft).review },
            cancel: { revision in try await connected().cancelReview(threadId: threadId, reviewId: review.id, revision: revision) }
        )
        let session = ReviewSession(threadId: threadId, review: review, service: service)
        let controller = ReviewWindowController(session: session, threadTitle: threads[threadId]?.title ?? "Thread", back: { [weak self] in
            self?.select(threadId)
            #if DEBUG
            if Automation.instanceId != nil { return }
            #endif
            NSApp.windows.first { $0.isVisible && !($0 is ReviewNativeWindow) && $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
        })
        controller.onClose = { [weak self] in self?.reviewWindows.removeValue(forKey: key) }
        reviewWindows[key] = controller
        controller.present()
    }

    func receiveReview(_ review: DesignReview, threadId: String) {
        reviewWindows[threadId + "/" + review.id]?.session.receive(review)
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
                        guard let client = app.client else { throw NSError(domain: "Threadbare", code: 1, userInfo: [NSLocalizedDescriptionKey: "The runner is disconnected."]) }
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

struct ReviewWindow: View {
    @Bindable var session: ReviewSession
    let back: () -> Void
    let close: () -> Void
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let note = session.review.note, !note.isEmpty {
                Text(note).font(.system(size: TypeScale.work)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
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
                filmstrip
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
        } message: { Text("The agent won’t receive a reply. You can still reopen the images.") }
        .task {
            await session.refresh()
            // Windows remain useful when another thread is selected and
            // its transcript subscription has been parked.
            while !Task.isCancelled && session.review.isPending {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await session.refresh()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Picker("View", selection: $session.mode) {
                ForEach(ReviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 228)
                .tip("All the images, two side by side, or one at a time (← → to move)")
            Text("\(session.review.options.count) images").foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Picker("Zoom", selection: $session.actualSize) {
                Text("Fit").tag(false)
                Text("100%").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                .tip("100% shows one image pixel per screen pixel. Scroll to read the rest.")
            Button("Back to thread", systemImage: "arrow.up.backward") { back() }
                .tip("Show the thread this review came from")
        }.font(.system(size: TypeScale.work)).padding(16)
    }

    @ViewBuilder private var canvases: some View {
        if session.mode == .grid {
            GeometryReader { geo in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(session.visibleIndices, id: \.self) { index in
                            option(index, slot: 0, grid: true).frame(height: max(270, (geo.size.height - 18) / 2))
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 6)
                }
            }
        } else {
            HStack(spacing: 14) {
                ForEach(Array(session.visibleIndices.enumerated()), id: \.element) { slot, index in
                    option(index, slot: slot, grid: false)
                }
            }.padding(.horizontal, 16)
        }
    }

    private func option(_ index: Int, slot: Int, grid: Bool) -> some View {
        let option = session.review.options[index]
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if grid {
                    Text("\(option.id). \(option.title)").fontWeight(.medium).lineLimit(1)
                } else {
                    Picker("Image", selection: Binding(get: { index }, set: { session.show($0, slot: slot) })) {
                        ForEach(Array(session.review.options.enumerated()), id: \.element.id) { i, item in
                            Text("\(item.id). \(item.title)").tag(i)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity)
                        .tip("Which image to show here")
                }
                Spacer(minLength: 4)
                if option.reference {
                    Text("Reference").foregroundStyle(.secondary).font(.system(size: TypeScale.detail))
                } else {
                    Button {
                        session.pick(option.id)
                    } label: {
                        Text(session.draft.pickedId == option.id ? "✓ Picked" : "Pick this")
                            .foregroundStyle(session.draft.pickedId == option.id ? Color.accentColor : Color.primary)
                    }.disabled(!session.editable)
                        .tip(session.draft.pickedId == option.id ? "Your pick" : "Pick this one. Your reply says which you picked.")
                }
            }.font(.system(size: TypeScale.work)).padding(12)
            Divider()
            ReviewCanvas(image: option.image, actualSize: session.actualSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("\(option.id). \(option.title). Scroll to inspect the image.")
            Divider()
            if grid {
                HStack {
                    Text(session.draft.notes[option.id]?.isEmpty == false ? "Has notes" : option.note ?? "")
                        .lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button(session.draft.notes[option.id]?.isEmpty == false ? "View notes" : "View and add notes") {
                        session.show(index, slot: 0)
                        session.mode = .single
                    }
                    .tip("Show this image on its own, with its notes")
                }.font(.system(size: TypeScale.detail)).padding(10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = option.note { Text(note).foregroundStyle(.secondary).lineLimit(2) }
                    Text("Notes on \(option.id)").foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { session.draft.notes[option.id] ?? "" }, set: { session.setNote($0, for: option.id) }))
                        .font(.system(size: TypeScale.work)).scrollContentBackground(.hidden)
                        .padding(6).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                        .frame(height: 74).disabled(!session.editable)
                        .accessibilityLabel("Notes on \(option.id)")
                }.font(.system(size: TypeScale.detail)).padding(12)
            }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(session.draft.pickedId == option.id ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(session.review.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        session.show(index, slot: session.mode == .pair ? 1 : 0)
                        if session.mode == .grid { session.mode = .single }
                    } label: {
                        HStack(spacing: 10) {
                            ReviewCanvas(image: option.image, actualSize: false).frame(width: 68, height: 46).allowsHitTesting(false)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(option.id). \(option.title)").font(.system(size: TypeScale.detail, weight: .medium)).lineLimit(1)
                                Text(option.reference ? "Reference" : session.draft.pickedId == option.id ? "✓ Picked" : "Option")
                                    .font(.system(size: TypeScale.small)).foregroundStyle(.secondary)
                            }
                        }.padding(8).frame(width: 225, alignment: .leading)
                            .background(Color.primary.opacity(session.visibleIndices.contains(index) ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .tip("\(option.id). \(option.title)")
                }
            }.padding(16)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status).font(.system(size: TypeScale.work, weight: .medium))
                Text(session.review.isPending ? (session.saving ? "Saving draft…" : session.dirty ? "Draft kept on this Mac" : "Draft saved. Nothing sent yet.") : "You can return to these images and notes any time.")
                    .font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
            }
            Spacer()
            if session.review.isPending {
                Menu {
                    Button("Cancel review", role: .destructive) { confirmingCancel = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .tip("More")
                Button("Review later") { close() }.disabled(session.submitting)
                    .tip("Close the window. Your draft is kept.")
                Button(session.submitting ? "Sending…" : "Send reply") { Task { await session.submit() } }
                    .buttonStyle(.borderedProminent).disabled(!session.canSubmit)
                    .tip("Send your pick and notes to the agent")
            } else {
                Button("Done") { close() }
                    .tip("Close the window")
            }
        }.padding(16).overlay(alignment: .top) { Divider() }
    }

    private var status: String {
        if session.review.status == "cancelled" { return "Review cancelled" }
        if !session.review.isPending && session.review.status != "answered" { return "Review closed" }
        let sent = session.review.response ?? session.draft
        let shown = session.review.isPending ? session.draft : sent
        let picked = session.review.options.first { $0.id == shown.pickedId }
        let notes = shown.notes.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        var text = picked.map { "\($0.id). \($0.title) picked" } ?? "No option picked"
        if notes > 0 { text += " · Notes on \(notes) image\(notes == 1 ? "" : "s")" }
        if session.review.status == "answered" { text += " · Reply sent" }
        return text
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
