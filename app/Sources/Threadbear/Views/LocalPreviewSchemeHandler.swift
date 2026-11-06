import Foundation
import ThreadbearCore
import WebKit

/// Serves local HTML previews as `threadbear-preview://<token>/<page>`,
/// answering only for what LocalPreviewSite allows: the page and the assets
/// it names in its folder. A `file://` load with read access to the folder
/// let a page read any file beside it (Daybreak finding 6). The page's own
/// scripts are off (WebPanelPool), so what it names can be shown, not read,
/// until Mike chooses Run them for those exact bytes (PreviewScriptConsent).
/// Then its scripts can read what it names, and everything below is what
/// keeps that on the screen.
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
    /// For a page running its scripts: frames of this scheme only, so a
    /// script can't make a data: or blob: frame to run in (clipboardGuard).
    static let scriptsPolicy = policy.replacingOccurrences(of: "frame-src \(scheme): data: blob:", with: "frame-src \(scheme):")
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

    /// In a view running the page's scripts, in every frame, first and in a
    /// world of its own (so the page can't reach these listeners): nothing
    /// is dragged or copied out of the page. A script there can read the
    /// assets the page names and could hand them to a drag or a copy, which
    /// go through the OS rather than the network (Codex review, 6 Nov 2026).
    static let scriptsGuard = """
    (() => {
      for (const type of ['dragstart', 'copy', 'cut']) {
        addEventListener(type, (e) => { e.preventDefault(); e.stopImmediatePropagation(); }, true);
      }
    })();
    """
    /// The same view, in the page's world, in every frame: no Clipboard
    /// API, and no `execCommand('copy')` or `'cut'`, either of which a
    /// script can use on any click in the page to put what it read on the
    /// pasteboard. WebKit writes those itself, past SealedPreviewWebView
    /// (Codex review). Defined before the page's scripts and not
    /// configurable, and a scripts-on page gets no data: or blob: frames
    /// (`scriptsPolicy`), where it could look for a copy of its own.
    static let clipboardGuard = """
    (() => {
      try { delete Navigator.prototype.clipboard; } catch (_) {}
      try { Object.defineProperty(Navigator.prototype, 'clipboard', { get: () => undefined, configurable: false }); } catch (_) {}
      // Everything the wrapper uses is taken now, before the page's scripts
      // can replace it, and the command is made a string once and that
      // string passed on: a name that reads "bold" to the check and "copy"
      // to WebKit got past the first version (Codex review).
      const exec = Document.prototype.execCommand;
      const apply = Reflect.apply, toString = String, lower = String.prototype.toLowerCase;
      Object.defineProperty(Document.prototype, 'execCommand', {
        value: function (command, showUI, value) {
          const name = toString(command);
          const key = apply(lower, name, []);
          if (key === 'copy' || key === 'cut') return false;
          return apply(exec, this, arguments.length > 2 ? [name, showUI, value] : arguments.length > 1 ? [name, showUI] : [name]);
        },
        writable: false, configurable: false,
      });
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
    /// With `pageDigest`, for a view running the page's scripts: the page is
    /// served only while its bytes match, and only to `owner`, so a script
    /// can't reach a site through another view's token.
    func address(for file: URL, pageDigest: String? = nil, owner: WKWebView? = nil) -> URL? {
        guard let site = LocalPreviewSite(file: file, pageDigest: pageDigest) else { return nil }
        // The static view and a scripts-on one of the same file are kept
        // apart, so loading one doesn't take the other's token away.
        let key = file.standardizedFileURL.path + "\n" + (pageDigest ?? "")
        if let old = tokens[key] { sites[old] = nil; owners[old] = nil }
        let token = UUID().uuidString.lowercased()
        tokens[key] = token
        sites[token] = site
        if let owner { owners[token] = ObjectIdentifier(owner) }
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = token
        c.path = "/" + site.page
        return c.url
    }

    /// The one view each scripts-on site answers.
    private var owners: [String: ObjectIdentifier] = [:]

    /// For tests: answers a request the way WebKit would see it answered.
    func respond(to url: URL) -> (response: HTTPURLResponse, data: Data) {
        guard url.scheme == Self.scheme, let token = url.host, let site = sites[token],
              let served = site.serve(url.path) else {
            let refused = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/plain", "Content-Security-Policy": Self.scriptsPolicy])!
            return (refused, Data("Not available to this preview.".utf8))
        }
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": served.mimeType, "Content-Length": "\(served.data.count)",
                                                "Content-Security-Policy": site.pageDigest == nil ? Self.policy : Self.scriptsPolicy])!
        return (ok, served.data)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if let token = url.host, let owner = owners[token], owner != ObjectIdentifier(webView) {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
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
