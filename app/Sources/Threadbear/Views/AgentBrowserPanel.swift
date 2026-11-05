import AppKit
import QuartzCore
import SwiftUI
import ThreadbearCore

/// A thread's pages in the agent's own Chrome, drawn in a panel.
///
/// It's real Chrome, with a profile folder of its own, so it never touches the
/// Chrome Mike is using; BrowserBear's agent/agent-host.mjs starts it and parks
/// each page's window in a corner of the screen. This panel connects to that
/// Chrome's debugging port, shows the page from `Page.startScreencast` and
/// sends Mike's mouse and keys back with `Input.*`, so he and the agent are in
/// the same page and nothing comes to the front. Measured on the M5, 5 Nov
/// 2026: 60 frames a second, 33 ms from a click to the frame showing it, and
/// about 2 MB/s.
///
/// Why not a real browser view in the window (CEF)? Google's sign-in rejects
/// it ("This browser or app may not be secure"), and it rejects headless Chrome
/// too, but takes real Chrome with the debugging port open. See
/// browser-research/embedding-landscape.md in misc.
enum AgentBrowser {
    static let panelId = "threadbear.browser"

    /// BrowserBear's folder.
    static var home: String {
        ProcessInfo.processInfo.environment["BROWSERBEAR_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/BrowserBear")
    }
}

struct AgentTab: Decodable, Identifiable, Equatable {
    var tabId: Int
    var targetId: String
    var url: String
    var title: String
    var thread: String?
    /// working, yours or idle (service/marks.mjs); nil when unmarked.
    var state: String?
    var action: String?
    /// The agent is waiting on `handoff --wait`, so Done means something.
    var finish: Bool?
    var status: String?
    /// Goes up each time the agent hands this tab to Mike.
    var handoffs: Int?
    var popup: Bool?
    var id: Int { tabId }
}

private struct AgentState: Decodable, Equatable {
    var port: Int
    var socket: String
    var chromePid: pid_t?
    var tabs: [AgentTab]
}

/// Reads the host's tabs.json. A second's lag is fine: it's for which tabs a
/// thread has and what the agent's doing, and the picture comes over the port.
@MainActor
final class AgentBrowserModel: ObservableObject {
    static let shared = AgentBrowserModel()

    @Published private(set) var tabs: [AgentTab] = []
    @Published private(set) var port = 0
    private var socket = ""
    private var timer: Timer?
    private var last: Data?

    private var chromePid: pid_t?
    /// The app Mike was in, for when Chrome takes the focus.
    private var lastApp: NSRunningApplication?
    /// Mike asked for Chrome's own window, so it's meant to come forward.
    var realWindowShown = false

    private init() {
        // A page's window.open brings its Chrome forward, however parked the
        // window is (5 Nov), and Chrome has no switch against it, so the focus
        // goes straight back to wherever Mike was.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        read()
        timer = .scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        guard let app else { return }
        guard let chromePid, app.processIdentifier == chromePid else {
            lastApp = app
            return
        }
        if !realWindowShown { lastApp?.activate() }
    }

    private func read() {
        let path = (AgentBrowser.home as NSString).appendingPathComponent("agent/tabs.json")
        guard let data = FileManager.default.contents(atPath: path), data != last else { return }
        last = data
        guard let state = try? JSONDecoder().decode(AgentState.self, from: data) else { return }
        tabs = state.tabs
        port = state.port
        socket = state.socket
        chromePid = state.chromePid
    }

    func tabs(for threadId: String) -> [AgentTab] { tabs.filter { $0.thread == threadId } }

    var available: Bool { port != 0 }

    func done(_ tab: AgentTab) { request("markDone", ["tab": tab.tabId]) }

    /// Mike typed an address with no page open yet: a page of this thread's.
    func open(_ url: String, thread: String) { request("open", ["profile": "agent", "url": url], thread: thread) }

    private func request(_ cmd: String, _ args: [String: Any], thread: String? = nil) {
        let path = socket
        guard !path.isEmpty else { return }
        Task.detached { AgentBrowserModel.send(path: path, cmd: cmd, args: args, thread: thread) }
    }

    /// One `{id, cmd, args}` line to BrowserBear's service. Nobody waits for
    /// the answer: the next tabs.json shows what happened.
    nonisolated private static func send(path: String, cmd: String, args: [String: Any], thread: String?) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var message: [String: Any] = ["id": 1, "cmd": cmd, "args": args]
        if let thread { message["thread"] = thread }
        guard connected == 0, var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Staying until it answers: a closed connection can drop the command.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var wait = timeval(tv_sec: 40, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.read(fd, &buffer, buffer.count)
    }
}

// MARK: - The panel

struct AgentBrowserPanel: View {
    let thread: ThreadSummary
    @ObservedObject private var model = AgentBrowserModel.shared
    @State private var chosen: Int?
    @State private var address = ""
    @State private var surface = AgentSurfaceHandle()
    @FocusState private var addressFocused: Bool

    private var tabs: [AgentTab] { model.tabs(for: thread.id) }

    /// The one picked, else the newest: a sign-in popup comes up by itself,
    /// and goes when it closes.
    private var tab: AgentTab? {
        tabs.first { $0.tabId == chosen } ?? tabs.max { $0.tabId < $1.tabId }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if tabs.count > 1 { tabStrip }
            if let tab, tab.state == "yours" { yourTurn(tab) }
            if let tab, model.port != 0 {
                AgentSurface(port: model.port, targetId: tab.targetId, handle: surface)
                    .id(tab.targetId)
            } else {
                PaneNote(text: "No pages open in this thread.")
            }
            if let tab, tab.state == "working", let action = tab.action { working(action) }
        }
        .onChange(of: tab?.url) { _, url in
            if !addressFocused { address = url.map(Self.shown) ?? "" }
        }
        .onAppear { address = tab.map { Self.shown($0.url) } ?? "" }
    }

    private static func shown(_ url: String) -> String { url == "about:blank" ? "" : url }

    private var toolbar: some View {
        HStack(spacing: zoomed(2)) {
            PaneHeaderButton(symbol: "chevron.left", help: "Back") { surface.evaluate("history.back()") }
            PaneHeaderButton(symbol: "chevron.right", help: "Forward") { surface.evaluate("history.forward()") }
            PaneHeaderButton(symbol: "arrow.clockwise", help: "Reload") { surface.send("Page.reload") }
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.label))
                .focused($addressFocused)
                .padding(.horizontal, zoomed(8))
                .padding(.vertical, zoomed(4))
                .background(SidebarMetrics.hover, in: RoundedRectangle(cornerRadius: zoomed(6)))
                .onSubmit(go)
            PaneHeaderButton(symbol: "macwindow", help: "Show Chrome's own window, for a passkey or a password manager's popup") {
                surface.showRealWindow()
            }
        }
        .padding(.horizontal, zoomed(6))
        .padding(.vertical, zoomed(4))
    }

    private func go() {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = (text.contains(".") && !text.contains(" ") ? "https://" : "https://www.google.com/search?q=") + text }
        if tab != nil { surface.send("Page.navigate", ["url": text]) } else { model.open(text, thread: thread.id) }
        addressFocused = false
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: zoomed(2)) {
                ForEach(tabs) { item in
                    Button { chosen = item.tabId } label: {
                        Text(item.title.isEmpty ? item.url : item.title)
                            .font(.system(size: TypeScale.label))
                            .lineLimit(1)
                            .frame(maxWidth: zoomed(160))
                            .padding(.horizontal, zoomed(8))
                            .padding(.vertical, zoomed(3))
                            .background(item.tabId == tab?.tabId ? SidebarMetrics.hover : .clear, in: RoundedRectangle(cornerRadius: zoomed(5)))
                    }
                    .buttonStyle(.plain)
                    .tip(item.url)
                }
            }
            .padding(.horizontal, zoomed(6))
        }
        .padding(.bottom, zoomed(4))
    }

    private func yourTurn(_ tab: AgentTab) -> some View {
        HStack(spacing: zoomed(8)) {
            Circle().fill(.orange).frame(width: zoomed(7), height: zoomed(7))
            Text("Your turn").font(.system(size: TypeScale.label, weight: .medium))
            Spacer()
            Button("Done") { model.done(tab) }
                .controlSize(.small)
                .tip("Tell the agent you've finished here")
        }
        .padding(.horizontal, zoomed(10))
        .padding(.vertical, zoomed(5))
    }

    private func working(_ action: String) -> some View {
        HStack(spacing: zoomed(6)) {
            Circle().fill(.green).frame(width: zoomed(6), height: zoomed(6))
            Text(action).font(.system(size: TypeScale.label)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, zoomed(10))
        .padding(.vertical, zoomed(4))
    }
}

/// Lets the toolbar reach whichever view is showing the page.
@MainActor
final class AgentSurfaceHandle {
    weak var view: AgentSurfaceView?
    func send(_ method: String, _ params: [String: Any] = [:]) { view?.stream?.send(method, params) }
    func evaluate(_ js: String) { send("Runtime.evaluate", ["expression": js, "userGesture": true]) }
    func showRealWindow() { view?.showRealWindow() }
}

struct AgentSurface: NSViewRepresentable {
    let port: Int
    let targetId: String
    let handle: AgentSurfaceHandle

    func makeNSView(context: Context) -> AgentSurfaceView {
        let view = AgentSurfaceView(port: port, targetId: targetId)
        handle.view = view
        return view
    }

    func updateNSView(_ view: AgentSurfaceView, context: Context) { handle.view = view }
}

// MARK: - The connection to the page

/// One page's debugging connection: frames in, commands out. Everything but
/// `send` runs on the socket's own queue, so a busy main thread doesn't hold up
/// the picture.
final class AgentStream: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let lock = NSLock()
    private var nextId = 1
    private var waiting: [Int: ([String: Any]) -> Void] = [:]
    /// The decoded picture, off the main thread.
    var onFrame: ((CGImage) -> Void)?
    /// A page's alert, confirm or prompt: nothing in the page moves until it's answered.
    var onDialog: (([String: Any]) -> Void)?
    /// The agent answered it first, or the page went.
    var onDialogClosed: (() -> Void)?

    init(port: Int, targetId: String) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/devtools/page/\(targetId)")!)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receive()
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func send(_ method: String, _ params: [String: Any] = [:], reply: (([String: Any]) -> Void)? = nil) {
        lock.lock()
        let id = nextId
        nextId += 1
        if let reply { waiting[id] = reply }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            if case .string(let text) = message { self.handle(text) }
            self.receive()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = m["id"] as? Int {
            lock.lock()
            let reply = waiting.removeValue(forKey: id)
            lock.unlock()
            reply?(m["result"] as? [String: Any] ?? [:])
            return
        }
        if m["method"] as? String == "Page.javascriptDialogOpening", let params = m["params"] as? [String: Any] {
            onDialog?(params)
            return
        }
        if m["method"] as? String == "Page.javascriptDialogClosed" {
            onDialogClosed?()
            return
        }
        guard m["method"] as? String == "Page.screencastFrame", let params = m["params"] as? [String: Any],
              let b64 = params["data"] as? String, let jpeg = Data(base64Encoded: b64),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return }
        onFrame?(image)
        // Chrome sends the next one when it's had this answer, so a slow Mac
        // gets fewer frames rather than a growing queue.
        if let sid = params["sessionId"] { send("Page.screencastFrameAck", ["sessionId": sid]) }
    }
}

// MARK: - The picture and Mike's input

final class AgentSurfaceView: NSView {
    private(set) var stream: AgentStream?
    private let port: Int
    private let targetId: String
    private var streamed: CGSize = .zero
    private var buttons = 0
    private var lastCursorLook = Date.distantPast
    private var realWindowShown = false

    init(port: Int, targetId: String) {
        self.port = port
        self.targetId = targetId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .topLeft
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private func start() {
        guard stream == nil else { return }
        let stream = AgentStream(port: port, targetId: targetId)
        // Off the main thread, in its own transaction: Core Animation allows
        // it, and the picture keeps moving while the app is busy.
        let target = layer
        stream.onFrame = { image in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target?.contents = image
            CATransaction.commit()
            CATransaction.flush()
        }
        stream.onDialog = { [weak self] params in
            DispatchQueue.main.async { self?.showDialog(params) }
        }
        stream.onDialogClosed = { [weak self] in
            DispatchQueue.main.async { self?.closeDialog() }
        }
        self.stream = stream
        stream.send("Page.enable")
        stream.send("Emulation.setFocusEmulationEnabled", ["enabled": true])
        streamed = .zero
        resizePage()
    }

    private func stop() {
        stream?.send("Page.stopScreencast")
        stream?.close()
        stream = nil
    }

    override func layout() {
        super.layout()
        resizePage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        streamed = .zero
        resizePage()
    }

    /// The page takes the panel's size, so it lays itself out for it, at the
    /// screen's own resolution. The agent sees the same page at the same size.
    private func resizePage() {
        guard let stream, let window, bounds.width > 10, bounds.height > 10, bounds.size != streamed else { return }
        streamed = bounds.size
        let scale = window.backingScaleFactor
        layer?.contentsScale = scale
        stream.send("Emulation.setDeviceMetricsOverride", [
            "width": Int(bounds.width), "height": Int(bounds.height), "deviceScaleFactor": scale, "mobile": false,
        ])
        stream.send("Page.startScreencast", [
            "format": "jpeg", "quality": 85, "everyNthFrame": 1,
            "maxWidth": Int(bounds.width * scale), "maxHeight": Int(bounds.height * scale),
        ])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private static func modifiers(_ event: NSEvent) -> Int {
        var bits = 0
        if event.modifierFlags.contains(.option) { bits |= 1 }
        if event.modifierFlags.contains(.control) { bits |= 2 }
        if event.modifierFlags.contains(.command) { bits |= 4 }
        if event.modifierFlags.contains(.shift) { bits |= 8 }
        return bits
    }

    private func mouse(_ type: String, _ event: NSEvent, button: String = "none", clicks: Int = 0) {
        let p = point(event)
        stream?.send("Input.dispatchMouseEvent", [
            "type": type, "x": p.x, "y": p.y, "button": button, "buttons": buttons,
            "clickCount": clicks, "modifiers": Self.modifiers(event),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A <select> would open Chrome's native menu on the parked window,
        // out of sight and holding up the page, so it opens here instead.
        let p = point(event)
        selectAt(p) { [weak self] handled in
            guard let self, !handled else { return }
            self.buttons |= 1
            self.mouse("mousePressed", event, button: "left", clicks: event.clickCount)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard buttons & 1 != 0 else { return }
        buttons &= ~1
        mouse("mouseReleased", event, button: "left", clicks: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) { mouse("mouseMoved", event) }

    override func mouseMoved(with event: NSEvent) {
        mouse("mouseMoved", event)
        lookAtCursor(point(event))
    }

    // Chrome's own context menu would open out of sight too, and it's a native
    // one the page can't answer past, so this is a small one of ours.
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("Back") { [weak self] in self?.stream?.send("Runtime.evaluate", ["expression": "history.back()"]) })
        menu.addItem(item("Forward") { [weak self] in self?.stream?.send("Runtime.evaluate", ["expression": "history.forward()"]) })
        menu.addItem(item("Reload") { [weak self] in self?.stream?.send("Page.reload") })
        menu.addItem(.separator())
        menu.addItem(item("Copy") { [weak self] in self?.editing("copy") })
        menu.addItem(item("Paste") { [weak self] in self?.editing("paste") })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action // the menu item doesn't keep its target
        return item
    }

    override func scrollWheel(with event: NSEvent) {
        let p = point(event)
        // Trackpad deltas are in points already; a wheel's are in lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        stream?.send("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": p.x, "y": p.y, "button": "none", "modifiers": Self.modifiers(event),
            "deltaX": -event.scrollingDeltaX * scale, "deltaY": -event.scrollingDeltaY * scale,
        ])
    }

    /// The pointer the page wants there, as the picture can't show it.
    private func lookAtCursor(_ p: CGPoint) {
        guard Date().timeIntervalSince(lastCursorLook) > 0.1 else { return }
        lastCursorLook = Date()
        stream?.send("Runtime.evaluate", [
            "expression": "(() => { const e = document.elementFromPoint(\(p.x), \(p.y)); return e ? getComputedStyle(e).cursor : '' })()",
            "returnByValue": true,
        ]) { reply in
            let cursor = (reply["result"] as? [String: Any])?["value"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow == true else { return }
                switch cursor {
                case "pointer": NSCursor.pointingHand.set()
                case "text": NSCursor.iBeam.set()
                case "grab", "grabbing": NSCursor.openHand.set()
                case "not-allowed": NSCursor.operationNotAllowed.set()
                default: NSCursor.arrow.set()
                }
            }
        }
    }

    // MARK: <select>

    private func selectAt(_ p: CGPoint, then: @escaping @MainActor (Bool) -> Void) {
        guard let stream else { return then(false) }
        let js = """
        (() => { const s = document.elementFromPoint(\(p.x), \(p.y))?.closest?.('select');
          if (!s || s.multiple || s.size > 1 || s.disabled) return null;
          window.__tbSelect = s; s.focus();
          return [...s.options].map((o, i) => ({ i, text: o.text, on: o.selected, off: o.disabled })); })()
        """
        stream.send("Runtime.evaluate", ["expression": js, "returnByValue": true]) { reply in
            let options = (reply["result"] as? [String: Any])?["value"] as? [[String: Any]]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let options else { return MainActor.assumeIsolated { then(false) } }
                MainActor.assumeIsolated { then(true) }
                self.showSelect(options, at: p)
            }
        }
    }

    /// The automation's choice for the next menu, as a real one would wait
    /// for a person: `pick` is the row to press.
    private var automationPick: Int?

    private func showSelect(_ options: [[String: Any]], at p: CGPoint) {
        let menu = NSMenu()
        for option in options {
            let index = option["i"] as? Int ?? 0
            let row = item(option["text"] as? String ?? "") { [weak self] in
                self?.stream?.send("Runtime.evaluate", ["expression": """
                (() => { const s = window.__tbSelect; if (!s) return; s.selectedIndex = \(index);
                  s.dispatchEvent(new Event('input', { bubbles: true })); s.dispatchEvent(new Event('change', { bubbles: true })); })()
                """, "userGesture": true])
            }
            row.state = option["on"] as? Bool == true ? .on : .off
            row.isEnabled = option["off"] as? Bool != true
            menu.addItem(row)
        }
        if let pick = automationPick {
            automationPick = nil
            if let row = menu.item(at: pick), let target = row.target as? MenuAction { target.fire() }
            return
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }

    // MARK: Automation

    func automate(_ c: [String: Any], in window: NSWindow) -> String {
        let x = (c["x"] as? Double) ?? 0, y = (c["y"] as? Double) ?? 0
        let at = convert(NSPoint(x: x, y: y), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        var flags: NSEvent.ModifierFlags = []
        for m in c["mods"] as? [String] ?? [] {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        automationPick = c["pick"] as? Int
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            .mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func key(_ chars: String, _ code: UInt16, _ type: NSEvent.EventType) -> NSEvent? {
            .keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: now, windowNumber: window.windowNumber, context: nil,
                      characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code)
        }
        switch c["do"] as? String {
        case "click":
            mouse(.leftMouseDown).map(window.sendEvent)
            // The press waits on a look for a <select>, so the release follows it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { mouse(.leftMouseUp).map(window.sendEvent) }
        case "right":
            mouse(.rightMouseDown).map(window.sendEvent)
        case "scroll":
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-((c["dy"] as? Double) ?? 0)), wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return "error no event" }
            scrollWheel(with: event)
        case "key":
            let chars = c["chars"] as? String ?? ""
            let code = UInt16(c["code"] as? Int ?? 0)
            guard let down = key(chars, code, .keyDown), let up = key(chars, code, .keyUp) else { return "error no event" }
            if flags.contains(.command), performKeyEquivalent(with: down) { return "ok key equivalent" }
            keyDown(with: down)
            keyUp(with: up)
        case "type":
            for ch in c["text"] as? String ?? "" {
                let text = String(ch)
                let code = KeyNames.code(forCharacter: text.lowercased())
                guard let down = key(text, code, .keyDown), let up = key(text, code, .keyUp) else { continue }
                keyDown(with: down)
                keyUp(with: up)
            }
        default:
            return "error do what?"
        }
        return "ok"
    }

    // MARK: Keys

    /// On a Mac, Chrome only edits text for a key sent this way if it's told
    /// which editing command the key means, as AppKit would normally work out.
    private static func editCommands(_ event: NSEvent) -> [String] {
        let cmd = event.modifierFlags.contains(.command)
        let alt = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let sel = shift ? "AndModifySelection" : ""
        switch event.keyCode {
        case 51: return [cmd ? "deleteToBeginningOfLine" : alt ? "deleteWordBackward" : "deleteBackward"]
        case 117: return [alt ? "deleteWordForward" : "deleteForward"]
        case 36, 76: return [alt ? "insertNewlineIgnoringFieldEditor" : "insertNewline"]
        case 48: return [shift ? "insertBacktab" : "insertTab"]
        case 123: return [cmd ? "moveToLeftEndOfLine\(sel)" : alt ? "moveWordLeft\(sel)" : "moveLeft\(sel)"]
        case 124: return [cmd ? "moveToRightEndOfLine\(sel)" : alt ? "moveWordRight\(sel)" : "moveRight\(sel)"]
        case 126: return [cmd ? "moveToBeginningOfDocument\(sel)" : alt ? "moveToBeginningOfParagraph\(sel)" : "moveUp\(sel)"]
        case 125: return [cmd ? "moveToEndOfDocument\(sel)" : alt ? "moveToEndOfParagraph\(sel)" : "moveDown\(sel)"]
        default: return []
        }
    }

    private func editing(_ command: String) {
        stream?.send("Input.dispatchKeyEvent", ["type": "rawKeyDown", "commands": [command]])
        stream?.send("Input.dispatchKeyEvent", ["type": "keyUp"])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": editing("selectAll")
        case "c": editing("copy")
        case "x": editing("cut")
        case "v": editing("paste")
        case "z": editing(shift ? "redo" : "undo")
        case "r": stream?.send("Page.reload")
        case "[": stream?.send("Runtime.evaluate", ["expression": "history.back()"])
        case "]": stream?.send("Runtime.evaluate", ["expression": "history.forward()"])
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func key(_ event: NSEvent, down: Bool) {
        let (code, vk) = KeyNames.lookup(event.keyCode)
        var params: [String: Any] = [
            "code": code, "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": Int(event.keyCode),
            "modifiers": Self.modifiers(event), "key": KeyNames.key(event, code: code),
        ]
        if down {
            let commands = Self.editCommands(event)
            let chars = event.characters ?? ""
            // Arrow keys and the like carry private-use characters, not text.
            let printable = !chars.isEmpty && !event.modifierFlags.contains(.command)
                && chars.unicodeScalars.allSatisfy { !(0xF700...0xF8FF).contains($0.value) && $0.value != 0x7F && $0.value != 0x1B && $0.value != 0x09 }
            params["type"] = printable ? "keyDown" : "rawKeyDown"
            if printable {
                params["text"] = chars
                params["unmodifiedText"] = event.charactersIgnoringModifiers ?? chars
            }
            if !commands.isEmpty { params["commands"] = commands }
            params["autoRepeat"] = event.isARepeat
        } else {
            params["type"] = "keyUp"
        }
        stream?.send("Input.dispatchKeyEvent", params)
    }

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    // MARK: Dialogs

    private var dialogSheet: NSWindow?

    private func closeDialog() {
        guard let sheet = dialogSheet else { return }
        dialogSheet = nil
        window?.endSheet(sheet)
    }

    private func showDialog(_ params: [String: Any]) {
        guard let window, dialogSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = params["message"] as? String ?? ""
        alert.addButton(withTitle: "OK")
        let type = params["type"] as? String
        if type != "alert" { alert.addButton(withTitle: "Cancel") }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        if type == "prompt" {
            field.stringValue = params["defaultPrompt"] as? String ?? ""
            alert.accessoryView = field
        }
        dialogSheet = alert.window
        alert.beginSheetModal(for: window) { [weak self] response in
            // Closed by closeDialog: already answered.
            guard self?.dialogSheet != nil else { return }
            self?.dialogSheet = nil
            var answer: [String: Any] = ["accept": response == .alertFirstButtonReturn]
            if type == "prompt" { answer["promptText"] = field.stringValue }
            self?.stream?.send("Page.handleJavaScriptDialog", answer)
        }
    }

    // MARK: Chrome's own window

    /// Chrome's own sheets (a passkey, a permission, a password manager's
    /// popup) aren't in the page, so they aren't in the picture. This brings the
    /// real window up to answer them, and a second press parks it again.
    func showRealWindow() {
        realWindowShown.toggle()
        let shown = realWindowShown
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let main = NSScreen.screens.first?.frame.height ?? 0
        stream?.send("Browser.getWindowForTarget") { [weak self] reply in
            guard let id = reply["windowId"] else { return }
            let bounds: [String: Any] = shown
                ? ["left": Int(screen.midX - 640), "top": Int(main - screen.maxY + 40)]
                : ["left": -100000, "top": 100000]
            self?.stream?.send("Browser.setWindowBounds", ["windowId": id, "bounds": bounds])
        }
        AgentBrowserModel.shared.realWindowShown = shown
    }
}

/// The names Chrome wants for a Mac key: the physical key's `code`, and the old
/// Windows key number that plenty of sites still read.
enum KeyNames {
    private static let table: [UInt16: (String, Int)] = {
        var map: [UInt16: (String, Int)] = [
            36: ("Enter", 13), 76: ("NumpadEnter", 13), 48: ("Tab", 9), 49: ("Space", 32), 51: ("Backspace", 8), 53: ("Escape", 27),
            117: ("Delete", 46), 123: ("ArrowLeft", 37), 124: ("ArrowRight", 39), 125: ("ArrowDown", 40), 126: ("ArrowUp", 38),
            115: ("Home", 36), 119: ("End", 35), 116: ("PageUp", 33), 121: ("PageDown", 34),
            27: ("Minus", 189), 24: ("Equal", 187), 33: ("BracketLeft", 219), 30: ("BracketRight", 221), 42: ("Backslash", 220),
            41: ("Semicolon", 186), 39: ("Quote", 222), 43: ("Comma", 188), 47: ("Period", 190), 44: ("Slash", 191), 50: ("Backquote", 192),
        ]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"),
            (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        for (code, letter) in letters { map[code] = ("Key\(letter)", Int(letter.unicodeScalars.first!.value)) }
        let digits: [(UInt16, Int)] = [(29, 0), (18, 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9)]
        for (code, digit) in digits { map[code] = ("Digit\(digit)", 48 + digit) }
        return map
    }()

    static func lookup(_ keyCode: UInt16) -> (String, Int) { table[keyCode] ?? ("", 0) }

    /// For the automation's typing.
    static func code(forCharacter text: String) -> UInt16 {
        if text == " " { return 49 }
        let name = text.first?.isNumber == true ? "Digit\(text)" : "Key\(text.uppercased())"
        return table.first { $0.value.0 == name }?.key ?? 0
    }

    static func key(_ event: NSEvent, code: String) -> String {
        switch code {
        case "Enter", "NumpadEnter": return "Enter"
        case "Tab", "Backspace", "Escape", "Delete", "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "Home", "End", "PageUp", "PageDown": return code
        case "Space": return " "
        default: return event.characters ?? ""
        }
    }
}
