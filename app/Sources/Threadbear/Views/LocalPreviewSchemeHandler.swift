import Foundation
import ThreadbearCore
import WebKit

/// Serves local HTML previews as `threadbear-preview://<token>/<page>`,
/// answering only for what LocalPreviewSite allows: the page and the assets
/// it names in its folder. A `file://` load with read access to the folder
/// let a page read any file beside it (Daybreak finding 6). JavaScript stays
/// on, as mockups use it; what a page can read is what's held back.
///
/// Each load gets a new token, so each is its own origin with a fresh list
/// of what it may read, and two previews can't read each other's files.
final class LocalPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "threadbear-preview"
    private var sites: [String: LocalPreviewSite] = [:]
    /// The newest token for each file, so a reload drops the one before.
    private var tokens: [String: String] = [:]

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
                                          headerFields: ["Content-Type": "text/plain"])!
            return (refused, Data("Not available to this preview.".utf8))
        }
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": served.mimeType, "Content-Length": "\(served.data.count)"])!
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
