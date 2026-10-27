import AppKit
import SwiftUI
import ThreadbareCore
import WebKit

/// The pane beside the transcript for a thread whose folder has panels:
/// tabs along the top, one panel below. A `url` panel is a web view kept
/// loaded between visits (WebPanelPool), so the Convex dashboard doesn't
/// reload every time Mike switches threads. An `image` panel asks the
/// runner for a fresh picture now and then while it's showing.
struct PanelPane: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        let active = app.activePanel(for: thread)
        VStack(spacing: 0) {
            PanelTabs(thread: thread, active: active)
            Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5)
            if let active {
                switch active.kind {
                case .url:
                    if let url = active.pageURL {
                        WebPanel(url: url)
                    } else {
                        PanelNote(text: "This panel has no page to show.")
                    }
                case .image:
                    ImagePanel(threadId: thread.id, panel: active)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The panel titles, the active one underlined, then Open in browser.
private struct PanelTabs: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let active: Panel?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(thread.panels) { panel in
                let isActive = panel.id == active?.id
                Button {
                    app.choosePanel(panel.id, in: thread.id)
                } label: {
                    Text(panel.title)
                        .font(.system(size: TypeScale.label, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: PanelTabs.height)
                        .overlay(alignment: .bottom) {
                            if isActive {
                                Rectangle().fill(Color.primary.opacity(0.8)).frame(height: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(panel.note ?? panel.title)
            }
            Spacer(minLength: 8)
            if let active, let url = active.pageURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: TypeScale.label, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: PanelTabs.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            }
        }
        .padding(.horizontal, 6)
    }

    static let height: CGFloat = 38
}

private struct PanelNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.label))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Web panels

/// A `url` panel. The web view comes from the pool and is moved into this
/// view's container, so leaving and coming back finds the page as it was.
private struct WebPanel: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WebPanelContainer { WebPanelContainer() }

    func updateNSView(_ container: WebPanelContainer, context: Context) {
        container.show(WebPanelPool.shared.webView(for: url))
    }
}

final class WebPanelContainer: NSView {
    func show(_ webView: WKWebView) {
        if webView.superview === self { return }
        subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// Web views by page, a few at a time. Each uses the default website data
/// store, so a dashboard login made in one sticks for the next thread with
/// the same project, and across launches.
@MainActor
final class WebPanelPool: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = WebPanelPool()
    private var views: [URL: WKWebView] = [:]
    private var order: [URL] = []
    static let capacity = 4

    func webView(for url: URL) -> WKWebView {
        if let existing = views[url] {
            order.removeAll { $0 == url }
            order.append(url)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .windowBackgroundColor
        view.load(URLRequest(url: url))
        views[url] = view
        order.append(url)
        while order.count > Self.capacity, let oldest = order.first {
            // Never drop the one just asked for; the oldest unused goes.
            order.removeFirst()
            if let gone = views.removeValue(forKey: oldest) { gone.removeFromSuperview() }
        }
        return view
    }

    /// Links that want a new window (OAuth sign-in pages, "open in new tab")
    /// load in the same view: there is no other window to give them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

// MARK: - Image panels

/// An `image` panel: the runner's latest picture (the Simulator's screen),
/// asked for again every few seconds while the panel is showing. Clicking
/// it opens the real Simulator.
private struct ImagePanel: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let panel: Panel
    @State private var render: PanelRender?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Button {
                    ImagePanel.openSimulator()
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .help("Open Simulator")
            } else {
                PanelNote(text: render?.note ?? "Taking a screenshot…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(threadId)/\(panel.id)") {
            // Fresh every few seconds while on screen; the task ends when
            // the panel goes away.
            while !Task.isCancelled {
                let result = await app.renderPanel(threadId: threadId, panelId: panel.id)
                if Task.isCancelled { return }
                render = result
                // A new NSImage each time: the file's name doesn't change.
                image = result?.image.flatMap { NSImage(contentsOfFile: $0.path) }
                try? await Task.sleep(for: .seconds(result?.image == nil ? 5 : 3))
            }
        }
    }

    static func openSimulator() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Resizing

/// The hairline between transcript and pane, draggable to resize the pane.
struct PanelResizeHandle: View {
    @Environment(AppModel.self) private var app
    /// The width of the whole detail column, for the clamp.
    let columnWidth: CGFloat
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.hairline))
            .frame(width: 0.5)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? app.panelWidth
                        startWidth = start
                        // The handle is on the pane's left: dragging left widens it.
                        app.setPanelWidth(start - value.translation.width, columnWidth: columnWidth)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        app.savePanelWidth()
                    }
            )
    }
}
