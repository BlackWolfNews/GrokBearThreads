import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

extension AppModel {
    /// Opens a review in a window of its own, most of the screen (Mike,
    /// 30 Oct): beside the thread as a dock tab the images were too small
    /// to compare.
    func openReview(threadId: String, review: DesignReview) {
        let key = threadId + "/" + review.id
        if let existing = reviewWindows[key] {
            existing.session.receive(review)
            existing.present()
            return
        }
        presentReviewWindow(makeReviewSession(threadId: threadId, review: review))
    }

    private func makeReviewSession(threadId: String, review: DesignReview) -> ReviewSession {
        // Resolve the client for each call: a review can stay open through
        // a runner handover and must not keep the disconnected client.
        func connected() throws -> RPCClient {
            // RPCError rather than a plain error, so ReviewSession can tell a
            // runner that's restarting from one that refused.
            guard let client else { throw RPCError.disconnected(nil) }
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
        window.contentView = NSHostingView(rootView: ReviewWindow(session: session, back: back, close: { [weak self] in self?.close() }).allowsWindowActivationEvents())
        // Up in the title bar rather than a row of their own, so the images
        // and the choices get that height. Wide enough for all of them, as an
        // accessory doesn't resize when some come and go.
        let buttons = NSHostingView(rootView: ReviewTitlebarButtons(session: session, back: back).allowsWindowActivationEvents())
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

/// Not private, so ReviewWindowTests can press keys in a real one.
final class ReviewNativeWindow: NSWindow {
    weak var reviewSession: ReviewSession?

    /// Holding Space shows today's version over the shot on show. Caught
    /// before the responder chain, as a focused button would take the
    /// Space press for itself; a text box keeps it for typing.
    override func sendEvent(_ event: NSEvent) {
        if (event.type == .keyDown || event.type == .keyUp), event.keyCode == 49, !(firstResponder is NSTextView),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let session = reviewSession {
            if event.type == .keyUp { session.peeking = false } else if !event.isARepeat, session.canPeek { session.peeking = true }
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        // Text editors own their arrows and Return. Outside an editor,
        // browsing works immediately without first clicking the canvas.
        if !(firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let session = reviewSession {
            switch event.keyCode {
            case 123: session.browse(-1); return // left: the shot before
            case 124: session.browse(1); return // right: the next shot
            case 126: session.jump(-1); return // up: the option before
            case 125: session.jump(1); return // down: the next option
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
                IconMenu {
                    Button("Cancel review", systemImage: "xmark.circle", role: .destructive) { confirmingCancel = true }
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

/// The review, as Mike picked on 4 Nov: the option on show big on the stage,
/// with its other shots in a strip under it and a mark for every shot of
/// every option; down the right, the options with their reasons and shots,
/// ticks for as many as he wants, and one reply box with Send. Before, each
/// extra shot was an option of its own (A2, A3) that couldn't be picked, a
/// single pick was all he could send, and he answered most reviews by
/// typing in the thread instead.
struct ReviewWindow: View {
    @Bindable var session: ReviewSession
    let back: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var replying: Bool

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
        VStack(spacing: 0) {
            if session.mode == .single, let option = session.shownOption { caption(option) }
            images
            stepper
        }
        // minWidth 0: the image view's own size mustn't push the rail away.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
    }

    /// Which option and shot this is, and the way to try it live.
    private func caption(_ option: ReviewOption) -> some View {
        let shots = option.allShots
        let shown = session.shownShot
        let index = shots.firstIndex(of: shown ?? shots[0]) ?? 0
        let title = shown?.title
        let where_ = shots.count > 1 ? "\(index + 1) of \(shots.count)" + (title.map { " \u{00B7} \($0)" } ?? "") : title ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(option.label).font(.system(size: TypeScale.work + 2, weight: .semibold)).lineLimit(1)
            Text(where_).font(.system(size: TypeScale.work)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if let baseline = session.baseline, session.canPeek {
                Button { session.peeking.toggle() } label: {
                    Label(baseline.title, systemImage: "rectangle.2.swap")
                        .font(.system(size: TypeScale.detail, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 26)
                        .foregroundStyle(session.peeking ? Color.white : Color.primary)
                        .background(session.peeking ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .tip(session.peeking ? "Back to \(session.focusedOption?.id ?? "it") (or let go of Space)" : "Flick to \(baseline.title): click, or hold Space")
            }
            if let link = option.url, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open live", systemImage: "arrow.up.right")
                        .font(.system(size: TypeScale.detail, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain).tip("Try \(option.id) running live: \(link)")
            }
        }
        .padding(.horizontal, 22).padding(.top, 14)
    }

    private var images: some View {
        GeometryReader { geo in
            let room = CGSize(width: max(0, geo.size.width - Self.stageInset * 2), height: max(0, geo.size.height - Self.stageInset * 2))
            Group {
                if session.mode == .single, let shot = session.shownShot {
                    enlarged(shot.image, size: room)
                } else {
                    let layout = ReviewGalleryLayout.best(
                        aspects: session.review.options.map { aspect($0.image) }, width: room.width, height: room.height, spacing: Self.cellSpacing,
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
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Back and next, the option's other shots, and a mark for every shot
    /// of every option, grouped under its letter, then the grid where
    /// they're all side by side to choose from. A mark or a shot takes you
    /// straight to it.
    private var stepper: some View {
        HStack(alignment: .center, spacing: 18) {
            stepButton("chevron.left", tip: session.mode == .all ? "Back to the last one (\u{2190})" : "Previous (\u{2190})",
                       enabled: session.canStepBack) { session.browse(-1) }
            if session.mode == .single, let option = session.focusedOption, option.allShots.count > 1 {
                filmstrip(option)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                ForEach(Array(session.review.options.enumerated()), id: \.element.id) { index, option in
                    marks(index, option)
                }
                Button { session.showAll() } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: session.mode == .all ? .semibold : .regular))
                        .foregroundStyle(session.mode == .all ? Color.primary : Color.secondary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).tip("See them all and choose (Esc)")
            }
            stepButton("chevron.right", tip: session.nextIsAll ? "See them all and choose (\u{2192})" : "Next (\u{2192})",
                       enabled: session.canStepForward, prominent: true) { session.browse(1) }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func filmstrip(_ option: ReviewOption) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(option.allShots.enumerated()), id: \.offset) { index, shot in
                let current = index == session.shot
                Button { session.enlarge(session.focused, shot: index) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ReviewThumb(path: shot.image.path, width: 92, height: 58)
                            .opacity(current ? 1 : 0.55)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(current ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
                        Text(shot.title ?? "\(index + 1)").font(.system(size: TypeScale.detail - 1))
                            .foregroundStyle(current ? Color.primary : Color.secondary).lineLimit(1).frame(width: 92, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).tip(shotTip(option, index))
            }
        }
    }

    private func shotTip(_ option: ReviewOption, _ index: Int) -> String {
        let shots = option.allShots
        guard shots.count > 1 else { return option.label }
        return "\(option.label), " + (shots[index].title ?? "shot \(index + 1)")
    }

    /// An option's letter and a dot per shot. A reference is hollow: it's
    /// there to look at, not to pick.
    private func marks(_ index: Int, _ option: ReviewOption) -> some View {
        let picked = session.draft.pickedIds.contains(option.id)
        let here = session.mode == .single && session.focused == index
        return HStack(spacing: 0) {
            Text(option.id).font(.system(size: TypeScale.detail - 1, weight: .semibold))
                .foregroundStyle(picked ? Color.accentColor : here ? Color.primary : Color.secondary)
                .lineLimit(1).padding(.trailing, 2)
            ForEach(Array(option.allShots.indices), id: \.self) { shot in
                let current = here && session.shot == shot
                let colour = picked ? Color.accentColor : current || here ? Color.primary : Color.secondary.opacity(0.45)
                Button { session.enlarge(index, shot: shot) } label: {
                    Group {
                        if option.reference { Circle().strokeBorder(colour, lineWidth: 1.5) } else { Circle().fill(colour) }
                    }
                    .frame(width: current ? 10 : 7, height: current ? 10 : 7)
                    .frame(width: 13, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).tip(shotTip(option, shot))
            }
        }
    }

    private func stepButton(_ symbol: String, tip: String, enabled: Bool, prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 50, height: 32)
                .background(Color.primary.opacity(prominent && enabled ? 0.1 : 0.05), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled).tip(tip)
    }

    private func aspect(_ image: ImageRef) -> Double {
        guard let width = image.width, let height = image.height, width > 0, height > 0 else { return 1100.0 / 760.0 }
        return Double(width) / Double(height)
    }

    /// One shot on the whole stage. A click goes back to all of them; at
    /// full size a click is for scrolling, so it does nothing.
    private func enlarged(_ image: ImageRef, size: CGSize) -> some View {
        let id = session.focusedOption?.id ?? ""
        let scrolling = session.actualSize
        let fit = ReviewGalleryLayout.fit(aspect: aspect(image), width: size.width, height: size.height)
        return ReviewCanvas(image: image, actualSize: scrolling, onClick: scrolling ? nil : { session.showAll() })
            .tip(scrolling ? "" : "\(id): click to see them all")
            .frame(width: scrolling ? size.width : fit.width, height: scrolling ? size.height : fit.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(session.focusedOption?.label ?? ""). Scroll to inspect the image.")
    }

    /// An option among them all: its first shot, and how many it has.
    private func cell(_ index: Int, size: CGSize) -> some View {
        let option = session.review.options[index]
        let picked = session.draft.pickedIds.contains(option.id)
        let count = option.allShots.count
        let room = CGSize(width: max(0, size.width - Self.cellPadding * 2), height: max(0, size.height - Self.cellPadding * 2 - Self.captionHeight))
        let fit = ReviewGalleryLayout.fit(aspect: aspect(option.image), width: room.width, height: room.height)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(option.id).font(.system(size: TypeScale.detail, weight: .semibold))
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                if count > 1 { Text("\(count) shots").font(.system(size: TypeScale.detail)).foregroundStyle(.tertiary) }
            }
            .lineLimit(1).frame(height: Self.captionHeight, alignment: .topLeading)
            ReviewCanvas(image: option.image, actualSize: false, onClick: { session.enlarge(index) })
                .tip("\(option.id): click to enlarge")
                .frame(width: fit.width, height: fit.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(option.label)
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
            ScrollViewReader { scroller in ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = session.review.note, !note.isEmpty {
                        Text(note).font(.system(size: TypeScale.work)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .padding(14)
                        Divider()
                    }
                    ForEach(Array(session.review.options.enumerated()), id: \.element.id) { index, option in
                        choice(option, index: index).id(option.id)
                        Divider()
                    }
                }
            }
            .onChange(of: session.focused) { _, index in
                guard session.review.options.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(session.review.options[index].id) }
            } }
            Divider()
            footer.padding(14)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func choice(_ option: ReviewOption, index: Int) -> some View {
        let picked = session.draft.pickedIds.contains(option.id)
        let note = (session.review.response ?? session.draft).notes[option.id] ?? ""
        let current = session.mode == .single && session.focused == index
        let shots = option.allShots
        return HStack(alignment: .top, spacing: 10) {
            pickMark(option, picked: picked)
            VStack(alignment: .leading, spacing: 8) {
                // The whole row shows its image, references too (Mike, 2 Nov).
                Button { if !current { session.enlarge(index) } } label: { choiceText(option) }
                    .buttonStyle(.plain)
                    .tip(current ? "Showing \(option.id)" : "Show \(option.id)")
                if shots.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(Array(shots.enumerated()), id: \.offset) { shot, item in
                            let on = current && session.shot == shot
                            Button { session.enlarge(index, shot: shot) } label: {
                                ReviewThumb(path: item.image.path, width: 52, height: 33)
                                    .opacity(on ? 1 : 0.7)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.primary : Color.clear, lineWidth: 1.5).padding(-2))
                            }.buttonStyle(.plain).tip(shotTip(option, shot))
                        }
                    }
                }
                // Notes on one option are from before the one reply box,
                // or a client that still sends them: shown, as they'll go.
                if !note.isEmpty {
                    Text(note).font(.system(size: TypeScale.work)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Color.primary.opacity(0.06) : picked ? Color.accentColor.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            if current { Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 3) }
        }
    }

    /// A tick, as several can be picked. A reference has none, and neither
    /// has a sent review's unpicked options; the gap keeps the text lined up.
    @ViewBuilder private func pickMark(_ option: ReviewOption, picked: Bool) -> some View {
        if session.editable && !option.reference {
            Button { session.pick(option.id) } label: {
                Image(systemName: picked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 16).padding(4).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(-4)
                .tip(picked ? "Unpick \(option.id)" : "Pick \(option.id)")
        } else if picked {
            Image(systemName: "checkmark.square.fill").font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 16, height: 16)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private func choiceText(_ option: ReviewOption) -> some View {
        HStack(alignment: .top, spacing: 0) {
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

    /// One box for what he thinks of the lot, as he'd say it in the thread.
    private var replyBox: some View {
        let reply = session.draft.reply ?? ""
        // Grows with what's typed: the hidden copy sets the height, and the
        // editor sits over it, as a TextEditor on its own takes all the
        // room the rail has left.
        return Text(reply + "\n").font(.system(size: TypeScale.work)).opacity(0)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                TextEditor(text: Binding(get: { session.draft.reply ?? "" }, set: { session.setReply($0) }))
                    .font(.system(size: TypeScale.work)).scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($replying)
                    .accessibilityLabel("Reply")
            }
            .overlay(alignment: .topLeading) {
                if reply.isEmpty {
                    Text("Add a reply").font(.system(size: TypeScale.work)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
        .padding(6)
        .background(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(replying ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
    }

    @ViewBuilder private var footer: some View {
        if session.review.isPending {
            VStack(spacing: 10) {
                replyBox
                HStack(spacing: 8) {
                    Button { session.toggleNone() } label: {
                        Text("None").frame(width: 70)
                    }
                    .buttonStyle(.bordered).controlSize(.large).tint(session.draft.none ? .accentColor : nil)
                    .disabled(!session.editable)
                    .tip(session.draft.none ? "Take back none of them" : "None of them will do")
                    Button {
                        Task {
                            await session.submit()
                            // Once it's sent there's nothing left to do here, so
                            // it gets out of the way (Mike, 28 Oct). A failed send
                            // stays open with its error and the reply kept.
                            if session.review.status == "answered" { close() }
                        }
                    } label: {
                        Text(session.sendLabel).fontWeight(.semibold).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canSubmit)
                    .tip("Send your picks and reply to the agent (\u{2318}\u{21A9}). Close the window to finish it later.")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                let sent = session.review.response ?? session.draft
                if sent.none { Text("None of them").font(.system(size: TypeScale.work, weight: .semibold)) }
                if let reply = sent.reply, !reply.isEmpty {
                    Text(reply).font(.system(size: TypeScale.work)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(status).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Done") { close() }.tip("Close it")
                }
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

/// A small picture of a shot, cropped from its top left, where a mockup's
/// title and controls are, rather than squashed.
private struct ReviewThumb: View {
    let path: String
    let width: CGFloat
    let height: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height, alignment: .topLeading)
            }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear(perform: load)
        .onChange(of: path) { _, _ in load() }
    }

    private func load() {
        ThumbnailLoader.shared.load(path: path, maxPixels: Int(width * 4)) { image = $0 }
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
