import Foundation
import ThreadbearCore
import WebKit

/// Serves local HTML previews as `threadbear-preview://<token>/<page>`,
/// answering only for what LocalPreviewSite allows: the page and the assets
/// it names in its folder. A `file://` load with read access to the folder
/// let a page read any file beside it (Daybreak finding 6). The page's own
/// scripts are off (WebPanelPool), so what it names can be shown, not read.
///
/// Each load gets a new token, so each is its own origin with a fresh list
/// of what it may read, and two previews can't read each other's files.
///
/// A page can still read a file beside it that its markup names, so it may
/// send nothing out: every answer carries `policy` as its
/// Content-Security-Policy (which a page can't loosen), and WebPanelPool
/// adds a content rule list blocking every load but this scheme's and
/// refuses navigating away, new windows and downloads.
final class LocalPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "threadbear-preview"
    /// Inline styles stay, for mockups (scripts are off anyway); everything
    /// else is this scheme's alone, or data: and blob: made on the page.
    static let policy = [
        "default-src \(scheme): 'unsafe-inline' 'unsafe-eval' data: blob:",
        "connect-src \(scheme):",
        "form-action 'none'",
        "frame-src \(scheme): data: blob:",
        "base-uri 'none'",
    ].joined(separator: "; ")
    /// In every frame, first: a click on a link (HTML or SVG, in a shadow
    /// root too) to anywhere but this scheme is cancelled before WebKit
    /// starts the navigation, which is when it would open a connection.
    static let linkGuard = """
    (() => {
      const own = '\(scheme):';
      addEventListener('click', (e) => {
        for (const node of e.composedPath()) {
          if (!node || !node.getAttribute) continue;
          const name = (node.localName || '').toLowerCase();
          if (name !== 'a' && name !== 'area') continue;
          const href = node.getAttribute('href') ?? node.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
          if (href == null) return;
          let target;
          try { target = new URL(href, document.baseURI).protocol; } catch (_) { target = ''; }
          if (target !== own) e.preventDefault();
          return;
        }
      }, true);
    })();
    """

    /// Everything blocked but this scheme's own loads.
    static let ruleList = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^\(scheme):"},"action":{"type":"ignore-previous-rules"}}]
    """
    private var sites: [String: LocalPreviewSite] = [:]
    /// The newest token for each file, so a reload drops the one before.
    private var tokens: [String: String] = [:]

    /// Whether `url` is this preview's own, the only place its view may go.
    static func isPreview(_ url: URL?) -> Bool {
        url?.scheme == scheme || url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc"
    }

    /// The address to load `file` at, or nil for a file that can't be a page.
    func address(for file: URL) -> URL? {
        guard let site = LocalPreviewSite(file: file) else { return nil }
        let key = file.standardizedFileURL.path
        if let old = tokens[key] { sites[old] = nil }
        let token = UUID().uuidString.lowercased()
        tokens[key] = token
        sites[token] = site
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = token
        c.path = "/" + site.page
        return c.url
    }

    /// For tests: answers a request the way WebKit would see it answered.
    func respond(to url: URL) -> (response: HTTPURLResponse, data: Data) {
        guard url.scheme == Self.scheme, let token = url.host, let site = sites[token],
              let served = site.serve(url.path) else {
            let refused = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/plain", "Content-Security-Policy": Self.policy])!
            return (refused, Data("Not available to this preview.".utf8))
        }
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": served.mimeType, "Content-Length": "\(served.data.count)",
                                                "Content-Security-Policy": Self.policy])!
        return (ok, served.data)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let (response, data) = respond(to: url)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // Answers are whole and immediate, so there's nothing to stop.
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
