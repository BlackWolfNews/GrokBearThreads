import AppKit
import ThreadbearCore

/// A file or page open in the pane in place of its section: a highlight, a
/// list panel's row, or a file linked from the transcript.
struct PanePreview: Equatable {
    enum Target: Equatable {
        case file(String)
        case page(URL)
        /// Words selected in the transcript, explained (`explainers`).
        case explain
    }

    var target: Target
    var title: String
    /// The section it was opened from, which Back goes to.
    var from: PaneSection
    /// Bumped each time it's opened, so opening the same file again reads
    /// it again (an agent rewrites its mockup between turns).
    var opened = 0
    /// A text file with its raw text up for editing (TextFileView).
    var editing = false

    var fileURL: URL? {
        if case .file(let path) = target { return URL(fileURLWithPath: path) }
        return nil
    }

    /// What Open hands to the default app or browser.
    var externalURL: URL? {
        switch target {
        case .file(let path): URL(fileURLWithPath: path)
        case .page(let url): url
        case .explain: nil
        }
    }
}

/// The pane's Highlights section and its preview (docs/protocol.md,
/// "Highlights"): fetching a thread's highlights, and opening what's in them.
extension AppModel {
    // MARK: Fetching

    /// Asks for a thread's highlights after `delay`, once however many times
    /// it's asked meanwhile: a busy turn moves `lastSeq` many times a
    /// second, and this keeps it to about one fetch a second.
    func refreshHighlights(_ threadId: String, after delay: Duration = .seconds(1)) {
        guard !highlightsUnsupported else { return }
        highlightWanted[threadId, default: 0] += 1
        guard highlightFetches[threadId] == nil else { return }
        highlightFetches[threadId] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            var fetched = -1
            while let self, fetched != self.highlightWanted[threadId], !self.highlightsUnsupported {
                fetched = self.highlightWanted[threadId] ?? 0
                await self.fetchHighlights(threadId)
            }
            self?.highlightFetches[threadId] = nil
        }
    }

    private func fetchHighlights(_ threadId: String) async {
        guard let client = client(for: threadId) else { return }
        do {
            let fresh = try await client.threadHighlights(threadId: threadId)
            if highlights[threadId] != fresh { highlights[threadId] = fresh }
            if let pin = highlightAutoShow.receive(fresh, threadId: threadId), let thread = threads[threadId] {
                // The agent asked to show Mike this (`pin` with `show`):
                // open it in the pane, as long as he's on that thread.
                if selection == threadId { open(pin, in: thread, external: false) }
            }
        } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
            highlightsUnsupported = true
        } catch {
            AppLog.write("rpc", "threads.highlights failed: \(error.localizedDescription)")
        }
    }

    /// Takes a highlight off for good. It goes from the list straight away;
    /// the runner's answer and the next fetch confirm it.
    func removeHighlight(_ highlight: Highlight, in threadId: String) {
        guard let client = client(for: threadId) else { return }
        highlights[threadId]?.highlights.removeAll { $0.id == highlight.id }
        Task {
            do {
                threads[threadId] = try await client.removeHighlight(threadId: threadId, highlightId: highlight.id)
            } catch {
                errorMessage = "Couldn't remove \(highlight.title): \(error.localizedDescription)"
            }
            refreshHighlights(threadId, after: .zero)
        }
    }

    // MARK: Opening

    /// A click on a highlight: a file previews in the pane, a page goes
    /// where "Default" says (openLink).
    /// `external` is Open in the context menu: always the default app or
    /// browser.
    func open(_ highlight: Highlight, in thread: ThreadSummary, external: Bool) {
        if highlight.path != nil, let away = awayFileNote(thread) {
            errorMessage = away
        } else if let path = highlight.path {
            if external { openExternally(URL(fileURLWithPath: path)) } else { preview(path: path, title: highlight.title, in: thread) }
        } else if let url = highlight.link {
            openLink(url, title: highlight.title, in: thread, external: external)
        }
    }

    /// A link from a highlight or a list panel's row: a file in the pane,
    /// a page where "Default" says (the browser unless Mike picked the
    /// panel).
    func openLink(_ url: URL, title: String? = nil, in thread: ThreadSummary, external: Bool = false) {
        if external {
            openExternally(url)
        } else if url.isFileURL {
            preview(path: url.path, title: title ?? url.lastPathComponent, in: thread)
        } else if PreviewRules.isWebPage(url), WebLinkAction.click == .panel {
            preview(page: url, title: title ?? HighlightText.address(url.absoluteString), in: thread)
        } else {
            openExternally(url)
        }
    }

    func preview(path: String, title: String? = nil, in thread: ThreadSummary) {
        show(PanePreview(target: .file(path), title: title ?? (path as NSString).lastPathComponent, from: paneSection(for: thread)), in: thread.id)
    }

    func preview(page url: URL, title: String, in thread: ThreadSummary) {
        show(PanePreview(target: .page(url), title: title, from: paneSection(for: thread)), in: thread.id)
    }

    func show(_ preview: PanePreview, in threadId: String) {
        var preview = preview
        preview.opened = (panePreview[threadId]?.opened ?? 0) + 1
        panePreview[threadId] = preview
        // Over the section it's from, opening that if it's closed.
        showPane(preview.from)
        // A page kept loaded from an earlier look is read again: the file
        // or the dev server has likely changed since.
        if let url = preview.externalURL, preview.fileURL.map({ PreviewRules.viewer(forPath: $0.path) == .web }) ?? true {
            WebPanelPool.shared.reloadIfLoaded(url)
        }
    }

    /// The bar's pencil (and Done) over a text file.
    func setPreviewEditing(_ editing: Bool, in threadId: String) {
        panePreview[threadId]?.editing = editing
    }

    /// Back, to the section the preview came from. An explanation is kept
    /// until the next one, though nothing shows it again yet.
    func closePreview(in threadId: String) {
        panePreview[threadId] = nil
    }

    func openExternally(_ url: URL) {
        // A page's `?clean&s=45` would be dropped on the way to the browser
        // (macOS passes a file URL on without them), so the page goes by a
        // little one that forwards to it, opened in the same app.
        if url.isFileURL, url.query != nil || url.fragment != nil,
           PreviewRules.viewer(forPath: url.path) == .web,
           let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: url.path)) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Threadbear-links", isDirectory: true)
            let page = folder.appendingPathComponent(UUID().uuidString + ".html")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FilePathRefs.forwardingPage(to: url).write(to: page, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            } catch {}
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// A click on a file link in the transcript does what Mike picked in
    /// its right-click menu (FileLinkAction.click); ⌘-click always opens
    /// it in its own app.
    func openTranscriptFileLink(_ url: URL, commandKey: Bool) -> Bool {
        openTranscriptFile(url, commandKey ? .app : FileLinkAction.click)
    }

    /// `url` is a file URL, perhaps with a `?query` or `#fragment` for the
    /// page (FilePathRefs.fileLink), which a page in the panel or the
    /// browser keeps.
    @discardableResult
    func openTranscriptFile(_ url: URL, _ action: FileLinkAction) -> Bool {
        if let thread = selectedThread, let away = awayFileNote(thread) {
            errorMessage = away
            return true
        }
        let path = url.path
        var action = action
        if action == .automatic { action = PreviewRules.previewsInPane(transcriptLink: url) ? .panel : .app }
        switch action {
        case .panel:
            // The pane belongs to a thread; on a project page there's none.
            guard let thread = selectedThread, openProjectId == nil else {
                openExternally(url)
                return true
            }
            if url.query != nil || url.fragment != nil, PreviewRules.viewer(forPath: path) == .web {
                preview(page: url, title: url.lastPathComponent, in: thread)
            } else {
                preview(path: path, in: thread)
            }
            return true
        case .finder:
            revealInFinder(path)
            return true
        case .app, .automatic:
            openExternally(url)
            return true
        }
    }

    /// A web link in the transcript, in the browser or the panel.
    @discardableResult
    func openTranscriptWebLink(_ url: URL, _ action: WebLinkAction) -> Bool {
        // The pane belongs to a thread; on a project page there's none.
        guard action == .panel, let thread = selectedThread, openProjectId == nil else { return NSWorkspace.shared.open(url) }
        preview(page: url, title: HighlightText.address(url.absoluteString), in: thread)
        return true
    }

    /// The file a transcript link names, as a file URL keeping any query
    /// and fragment: a file link itself, or a path in inline code found
    /// from the selected thread's folder and what its tools touched
    /// (FilePathRefs). Nil for one that names nothing.
    func transcriptLinkFile(_ url: URL) -> URL? {
        // Another runner's paths are that Mac's: nothing here to open.
        if selectedThread?.isRemote == true { return nil }
        if url.isFileURL { return url }
        guard let text = FilePathRefs.text(of: url) else { return nil }
        let thread = selectedThread
        let known = thread.flatMap { loadedSession($0.id) }.map { FilePathRefs.toolPaths($0.model.items) } ?? []
        return FilePathRefs.fileLink(text, root: thread?.cwd, known: known)
    }

    /// Files in another runner's thread are on that Mac, so a click on one
    /// says so rather than open whatever this Mac has at that path.
    func awayFileNote(_ thread: ThreadSummary) -> String? {
        runnerName(of: thread).map { "That file is on \($0), not this Mac." }
    }

    /// A click on a path in inline code. One that names nothing beeps.
    func openTranscriptPathRef(_ text: String, commandKey: Bool) -> Bool {
        if let thread = selectedThread, let away = awayFileNote(thread) {
            errorMessage = away
            return true
        }
        guard let url = FilePathRefs.url(for: text), let file = transcriptLinkFile(url) else {
            NSSound.beep()
            return false
        }
        return openTranscriptFileLink(file, commandKey: commandKey)
    }
}
