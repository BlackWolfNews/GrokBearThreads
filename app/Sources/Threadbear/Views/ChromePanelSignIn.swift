import AppKit
import Network
import SwiftUI
import ThreadbearCore

/// One short-lived listener per sign-in. Its random URL is never sent to
/// the runner or logged. It listens only on IPv4 loopback, never the LAN.
@MainActor
final class ChromePanelSignIn: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var waiting = false
    @Published private(set) var finished = false
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var flow: ConvexPanelSignIn?
    private var port: NWEndpoint.Port?
    private var onCallback: ((URL) -> Void)?
    private let openPage: ((URL) -> Void)?

    init(openPage: ((URL) -> Void)? = nil) { self.openPage = openPage }

    static var chromeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    func start(dashboard: URL, onCallback: @escaping (URL) -> Void) {
        cancel()
        finished = false
        guard openPage != nil || Self.chromeURL != nil else { message = "Install Google Chrome to use this sign-in."; return }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let flow = ConvexPanelSignIn(dashboardURL: dashboard, nonce: nonce) else { return }
        self.flow = flow
        self.onCallback = onCallback
        waiting = true
        message = "Opening Chrome…"
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { self.fail("Couldn’t open the sign-in page."); return }
                        self.port = port
                        self.openChrome(flow: flow, port: port)
                    case .failed: self.fail("Couldn’t start sign-in. Try again.")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.fail("This sign-in expired. Try again to open a fresh page in Chrome.")
            }
        } catch { fail("Couldn’t start sign-in. Try again.") }
    }

    private func openChrome(flow: ConvexPanelSignIn, port: NWEndpoint.Port) {
        var page = URLComponents(string: "http://127.0.0.1:\(port.rawValue)\(flow.startPath)")!
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "login", value: flow.loginURL.absoluteString)]
        page.percentEncodedFragment = fragment.percentEncodedQuery
        guard let url = page.url else { fail("Couldn’t open Chrome."); return }
        if let openPage { openPage(url); return }
        guard let chrome = Self.chromeURL else { fail("Couldn’t open Chrome."); return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.waiting else { return }
                if error != nil { self.fail("Couldn’t open Chrome. Try again.") }
                else { self.message = "In Chrome, click the Threadbear Convex Sign-in extension, then finish signing in." }
            }
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        onCallback = nil
        flow = nil
        port = nil
        waiting = false
    }

    private func fail(_ text: String) { cancel(); message = text }

    private func accept(_ connection: NWConnection) {
        guard waiting, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, data: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let connection, self.connections[id] === connection else { return }
            self.connections.removeValue(forKey: id)
            connection.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384 - data.count) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] === connection else { return }
                var data = data
                data.append(chunk ?? Data())
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, id: id, data: data)
                } else if error != nil || complete || data.count >= 16384 {
                    self.connections.removeValue(forKey: id)
                    connection.cancel()
                } else { self.receive(connection, id: id, data: data) }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, data: Data) {
        guard let flow, let port, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let valid = first.count == 3 && first[0] == "GET" && first[2] == "HTTP/1.1"
            && hosts.count == 1 && hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port.rawValue)"
            && !lines.contains(where: { $0.lowercased().hasPrefix("origin:") })
        var callback: URL?
        let text: String
        let status: String
        if valid && first[1] == flow.startPath {
            status = "200 OK"
            text = "<h1>Sign in to Convex for Threadbear</h1><p>Click the puzzle piece in Chrome’s toolbar, then <b>Threadbear Convex Sign-in</b>. Finish signing in and Threadbear will load the dashboard in your panel.</p><p>Nothing happens when you click it? The extension isn’t added yet: go back to Threadbear and follow step 1 in the sign-in window.</p>"
        } else if valid, let result = flow.callback(requestTarget: first[1]) {
            callback = result
            // Consume before replying so a second connection cannot replay it.
            self.flow = nil
            listener?.cancel()
            listener = nil
            timeout?.cancel()
            status = "200 OK"
            text = "<h1>Returning to Threadbear</h1><p>Convex is finishing sign-in inside your panel. You can close this tab.</p>"
        } else {
            status = "400 Bad Request"
            text = "<h1>Sign-in link not accepted</h1><p>Return to Threadbear and start a fresh sign-in.</p>"
        }
        let body = Data(("<!doctype html><meta charset=\"utf-8\"><title>Threadbear Convex sign-in</title><style>body{font:17px system-ui;max-width:620px;margin:80px auto;padding:24px;line-height:1.6;color-scheme:light dark}h1{font-size:26px}</style>" + text).utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
        let completion = onCallback
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeValue(forKey: id)
            }
        })
        if let callback {
            onCallback = nil
            waiting = false
            finished = true
            message = "Convex is finishing sign-in in the panel."
            completion?(callback)
        }
    }

    /// A stable folder is needed because Chrome remembers the unpacked
    /// extension's path, while the app's update bundles are replaced.
    static func extensionFolder(at destination: URL? = nil) throws -> URL {
        guard let source = Bundle.module.url(forResource: "ChromeSignIn", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = destination ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Threadbear/ChromeSignIn", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["manifest.json", "bridge.mjs", "worker.mjs"] {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            try data.write(to: target.appendingPathComponent(name), options: .atomic)
        }
        return target
    }
}

/// Laid out as numbered steps with each button beside the step it belongs
/// to, because a row of unrelated buttons left it unclear what to do first.
struct ChromePanelSignInSheet: View {
    let dashboard: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ChromePanelSignIn()
    /// Set after the first sign-in that comes back, which proves the
    /// extension is loaded. Until then the one-time setup step shows first.
    @AppStorage("chromeSignInExtensionWorked") private var extensionWorked = false
    @State private var showSetup = false
    @State private var setupError: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to Convex with Chrome").font(.title2.weight(.semibold))
                Text("You log in to Convex in Chrome as usual, and a small Chrome extension hands the login back to this panel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.finished {
                Label("Signed in. The dashboard is loading in the panel.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                steps
            }
            if let setupError { Text(setupError).foregroundStyle(.red) }
            HStack {
                if extensionWorked && !showSetup && !session.finished {
                    Button("Set up the extension again") { showSetup = true }
                        .buttonStyle(.link)
                        .tip("Show the one-time steps for adding the extension to Chrome")
                }
                Spacer()
                Button(session.finished ? "Done" : "Cancel") { dismiss() }
                    .tip(session.finished ? "Close sign-in" : "Cancel this sign-in")
                    .keyboardShortcut(session.finished ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: session.finished) { _, done in if done { extensionWorked = true } }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder private var steps: some View {
        let setup = !extensionWorked || showSetup
        VStack(alignment: .leading, spacing: 14) {
            if setup {
                SignInStep(number: 1, title: "Add the extension to Chrome (one time only)") {
                    Text("In Chrome, go to chrome://extensions, turn on Developer mode (top right), click Load unpacked and pick the ChromeSignIn folder.")
                        .textSelection(.enabled)
                    HStack {
                        Button(copied ? "Copied" : "Copy chrome://extensions") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("chrome://extensions", forType: .string)
                            copied = true
                        }
                        .tip("Copy the address of Chrome's extensions page, to paste into Chrome")
                        Button("Show folder in Finder") {
                            do {
                                let folder = try ChromePanelSignIn.extensionFolder()
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                                setupError = nil
                            } catch { setupError = "Couldn’t prepare the extension folder. Try again." }
                        }
                        .tip("Show the ChromeSignIn folder to pick in Chrome's Load unpacked")
                    }
                }
            }
            SignInStep(number: setup ? 2 : 1, title: "Open the Convex login in Chrome") {
                Button(session.waiting ? "Open it again" : "Open in Chrome") {
                    session.start(dashboard: dashboard) { callback in
                        WebPanelPool.shared.finishSignIn(callback, for: dashboard)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tip("Open a fresh Convex sign-in page in Google Chrome")
            }
            SignInStep(number: setup ? 3 : 2, title: "In Chrome, click the extension, then log in") {
                Text("Click the puzzle piece in Chrome's toolbar, then Threadbear Convex Sign-in. Log in to Convex as normal and this panel signs in by itself.")
                if session.waiting || !session.message.isEmpty {
                    Text(session.message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}

private struct SignInStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
