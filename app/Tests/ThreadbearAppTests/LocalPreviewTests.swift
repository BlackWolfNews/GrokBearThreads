import WebKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// Daybreak finding 6, in a real web view: a local HTML preview served by
/// the pool's scheme handler can load the style and picture it names, and
/// can't read a file beside it, by fetch, by file URL or by a picture's name.
@MainActor
final class LocalPreviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ data: Data) throws {
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// A 1x1 PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testAPreviewLoadsWhatItNamesAndNothingBesideIt() async throws {
        try write("style.css", Data("body { color: rgb(1, 2, 3); }".utf8))
        try write("pic.png", png)
        try write("secret.png", png)
        try write(".env", Data("SECRET=hunter2".utf8))
        try write("notes.txt", Data("private".utf8))
        // The secret's names are built at run time, so the page never names them.
        try write("index.html", Data("""
        <!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body>
        <img id="pic" src="pic.png">
        <script>
        const dot = '.', n = (a, b) => a + b;
        async function tryRead(path) {
          try { const r = await fetch(path); return r.ok ? 'read:' + (await r.text()) : 'refused:' + r.status; }
          catch (e) { return 'refused:error'; }
        }
        function tryPicture(path) {
          return new Promise(done => { const i = new Image(); i.onload = () => done('read'); i.onerror = () => done('refused'); i.src = path; });
        }
        window.results = null;
        window.addEventListener('load', async () => {
          window.results = {
            env: await tryRead(dot + 'env'),
            notes: await tryRead(n('notes', '.txt')),
            fileURL: await tryRead('file://' + \(String(reflecting: dir.path)) + '/' + dot + 'env'),
            secretPicture: await tryPicture(n('secret', '.png')),
            climb: await tryRead(n('..', '/') + 'x.png'),
            picture: document.getElementById('pic').naturalWidth,
            color: getComputedStyle(document.body).color,
          };
        });
        </script></body></html>
        """.utf8))

        let pool = WebPanelPool(defaults: UserDefaults(suiteName: "LocalPreviewTests.\(UUID().uuidString)")!)
        let view = pool.webView(for: dir.appendingPathComponent("index.html"))
        var results: [String: Any]?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let got = try? await view.evaluateJavaScript("window.results") as? [String: Any] { results = got; break }
        }
        let r = try XCTUnwrap(results, "the page never finished")
        XCTAssertEqual(view.url?.scheme, LocalPreviewSchemeHandler.scheme)
        // Its own style and picture still load.
        XCTAssertEqual(r["color"] as? String, "rgb(1, 2, 3)")
        XCTAssertEqual((r["picture"] as? NSNumber)?.intValue, 1)
        // Nothing beside it.
        XCTAssertEqual(r["env"] as? String, "refused:404")
        XCTAssertEqual(r["notes"] as? String, "refused:404")
        XCTAssertEqual(r["secretPicture"] as? String, "refused")
        XCTAssertEqual(r["climb"] as? String, "refused:404")
        XCTAssertEqual((r["fileURL"] as? String)?.hasPrefix("refused"), true)
    }
}
