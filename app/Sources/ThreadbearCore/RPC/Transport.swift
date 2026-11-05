import Foundation

/// One message-oriented connection to the runner. The real one is a WebSocket;
/// tests use a fake.
public protocol RPCTransport: AnyObject, Sendable {
    /// Connects. Throws `RPCError.connectFailed` or `.unauthorized`.
    func open() async throws
    func send(_ text: String) async throws
    /// The next incoming message. Throws `RPCError.disconnected` once closed.
    func receive() async throws -> Data
    func close()
}

/// WebSocket transport built on URLSessionWebSocketTask. `open()` returns
/// once the runner has proved it has the token and the app has proved the
/// same back (`RunnerAuth`, docs/protocol.md "Auth"); the token itself is
/// never sent, so a listener that took the runner's port while it was down
/// gets nothing it can reuse.
public final class WebSocketTransport: NSObject, RPCTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private let token: String
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closeCode: Int?
    private var authTimedOut = false
    private let authTimeout: Duration

    public init(url: URL, token: String, authTimeout: Duration = .seconds(5)) {
        self.url = url
        self.token = token
        self.authTimeout = authTimeout
    }

    public func open() async throws {
        // No Authorization header: the bearer token never leaves the app.
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.webSocketTask(with: request)
        // threads.events pages can be several MB; the default limit is 1 MB.
        task.maximumMessageSize = 256 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { openContinuation = continuation }
            task.resume()
        }
        try await authenticate(task)
    }

    /// The challenge, before anything the server says is passed on. Nothing
    /// but a challenge and then the right proof gets through: no fallback to
    /// the token, whatever the server claims to be.
    private func authenticate(_ task: URLSessionWebSocketTask) async throws {
        let timeout = authTimeout
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock { self.authTimedOut = true }
            task.cancel(with: .policyViolation, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            let (request, expected) = try RunnerAuth.answer(challenge: try await authReceive(task), token: token, dialedPort: RunnerAuth.loopbackPort(url))
            try await task.send(.string(request))
            try RunnerAuth.check(reply: try await authReceive(task), expected: expected)
        } catch let error as RunnerAuth.NotProved {
            task.cancel(with: .policyViolation, reason: nil)
            throw RPCError.connectFailed("it didn't prove it's the runner: \(error.reason)")
        } catch let error as RPCError {
            throw error
        } catch {
            if lock.withLock({ authTimedOut }) { throw RPCError.connectFailed("it didn't prove it's the runner in time") }
            throw RPCError.disconnected(error.localizedDescription)
        }
    }

    private func authReceive(_ task: URLSessionWebSocketTask) async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: return Data()
            }
        } catch {
            if lock.withLock({ authTimedOut }) { throw RPCError.connectFailed("it didn't prove it's the runner in time") }
            if lock.withLock({ closeCode }) == 4401 || task.closeCode.rawValue == 4401 { throw RPCError.unauthorized }
            throw RPCError.disconnected(error.localizedDescription)
        }
    }

    public func send(_ text: String) async throws {
        guard let task = lock.withLock({ self.task }) else { throw RPCError.disconnected(nil) }
        do {
            try await task.send(.string(text))
        } catch {
            throw RPCError.disconnected(error.localizedDescription)
        }
    }

    public func receive() async throws -> Data {
        guard let task = lock.withLock({ self.task }) else { throw RPCError.disconnected(nil) }
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: return Data()
            }
        } catch {
            // The delegate's close callback can land after this error, so
            // check the task's own close code too.
            if lock.withLock({ closeCode }) == 4401 || task.closeCode.rawValue == 4401 { throw RPCError.unauthorized }
            throw RPCError.disconnected(error.localizedDescription)
        }
    }

    public func close() {
        let (task, session) = lock.withLock { (self.task, self.session) }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finishOpen(_ error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let continuation = openContinuation
            openContinuation = nil
            return continuation
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finishOpen(nil)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { self.closeCode = closeCode.rawValue }
        finishOpen(closeCode.rawValue == 4401 ? RPCError.unauthorized : RPCError.disconnected("closed \(closeCode.rawValue)"))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if status == 401 || status == 403 {
            finishOpen(RPCError.unauthorized)
        } else {
            finishOpen(RPCError.connectFailed(error?.localizedDescription ?? "Connection closed"))
        }
    }
}
