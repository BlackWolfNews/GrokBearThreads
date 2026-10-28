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
        guard let client else { return }
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
        guard let client else { return }
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

    /// A click on a highlight: a file previews in the pane, a local page
    /// too, anything on the web goes to the browser (where the sign-ins
    /// are). `external` is Open in the context menu: always the default
    /// app or browser.
    func open(_ highlight: Highlight, in thread: ThreadSummary, external: Bool) {
        if let path = highlight.path {
            if external { openExternally(URL(fileURLWithPath: path)) } else { preview(path: path, title: highlight.title, in: thread) }
        } else if let url = highlight.link {
            openLink(url, title: highlight.title, in: thread, external: external)
        }
    }

    /// A link from a highlight or a list panel's row, by PreviewRules.
    func openLink(_ url: URL, title: String? = nil, in thread: ThreadSummary, external: Bool = false) {
        if !external, PreviewRules.place(for: url) == .pane {
            if url.isFileURL { preview(path: url.path, title: title ?? url.lastPathComponent, in: thread) } else { preview(page: url, title: title ?? HighlightText.address(url.absoluteString), in: thread) }
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
        panelsShown = true
        // A page kept loaded from an earlier look is read again: the file
        // or the dev server has likely changed since.
        if let url = preview.externalURL, preview.fileURL.map({ PreviewRules.viewer(forPath: $0.path) == .web }) ?? true {
            WebPanelPool.shared.reloadIfLoaded(url)
        }
    }

    /// Back, to the section the preview came from. An explanation is kept
    /// until the next one, though nothing shows it again yet.
    func closePreview(in threadId: String) {
        panePreview[threadId] = nil
    }

    func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// A click on a file link in the transcript: a file Mike would review
    /// (a mockup, a doc, a picture) opens in the pane beside it; ⌘-click,
    /// and anything else, opens in its own app as before.
    func openTranscriptFileLink(_ url: URL, commandKey: Bool) -> Bool {
        if !commandKey, PreviewRules.previewsInPane(transcriptLink: url), let thread = selectedThread, openProjectId == nil {
            preview(path: url.path, in: thread)
            return true
        }
        return NSWorkspace.shared.open(url)
    }
}
