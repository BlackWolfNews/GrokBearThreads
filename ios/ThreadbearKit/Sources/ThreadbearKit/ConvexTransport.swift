import Foundation
import ConvexMobile

/// Raw JSON in and out of Convex. The real one wraps convex-swift; tests
/// use a fake. Adapted from Poddle's ConvexTransport (no Convex Auth here:
/// the phone token travels as an argument).
public protocol ConvexTransport: Sendable {
    func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data
    func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data
    /// A live query: yields every new result, finishes with an error if the
    /// function throws.
    func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error>
    /// `true` while the WebSocket is connected.
    func connectionStates() -> AsyncStream<Bool>
}

public enum TransportError: Error, Sendable, Hashable, LocalizedError {
    /// The phone token was refused: missing, wrong or expired.
    case unauthorized(String)
    /// The function threw. Retrying won't help.
    case server(String)
    /// Couldn't reach the deployment.
    case network(String)
    /// The thread or command isn't in the mirror (deleted, or not yet written).
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case let .unauthorized(m): "Not paired: \(m)"
        case let .server(m): m
        case let .network(m): "Network: \(m)"
        case let .notFound(m): m
        }
    }
}

/// The real transport over convex-swift's Rust client, talking to its
/// UniFFI layer directly so results stay raw JSON.
public final class ConvexMobileTransport: ConvexTransport, @unchecked Sendable {
    private let client: MobileConvexClient
    private let socket = SocketWatcher()

    public init(deploymentURL: URL) {
        client = MobileConvexClient(
            deploymentUrl: deploymentURL.absoluteString, clientId: "threadbear-ios", webSocketStateSubscriber: socket
        )
    }

    private static func encode(_ args: [String: JSONValue]) -> [String: String] { args.mapValues(\.jsonString) }

    public func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        try await call { try await client.query(name: name, args: Self.encode(args)) }
    }

    public func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        try await call { try await client.mutation(name: name, args: Self.encode(args)) }
    }

    private func call(_ body: () async throws -> String) async throws -> Data {
        do { return Data(try await body().utf8) } catch { throw Self.map(error) }
    }

    public func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let subscriber = Subscriber(continuation)
        let client = client
        let encoded = Self.encode(args)
        let task = Task {
            do {
                let handle = try await client.subscribe(name: name, args: encoded, subscriber: subscriber)
                subscriber.attach(handle)
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            subscriber.cancel()
        }
        return stream
    }

    public func connectionStates() -> AsyncStream<Bool> { socket.stream() }

    /// phone.ts throws `ConvexError({kind: "auth" | "notFound", message})`.
    static func map(_ error: Error) -> TransportError {
        guard let e = error as? ClientError else { return .network(error.localizedDescription) }
        switch e {
        case let .ConvexError(data):
            let value = try? JSONValue.decode(Data(data.utf8))
            let message = value?["message"]?.string ?? data
            switch value?["kind"]?.string {
            case "auth": return .unauthorized(message)
            case "notFound": return .notFound(message)
            default: return .server(message)
            }
        case let .ServerError(msg): return .server(msg)
        case let .InternalError(msg): return .network(msg)
        }
    }

    private final class Subscriber: QuerySubscriber, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var handle: SubscriptionHandle?
        private var cancelled = false

        init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

        func attach(_ handle: SubscriptionHandle) {
            lock.lock()
            let wasCancelled = cancelled
            if !wasCancelled { self.handle = handle }
            lock.unlock()
            if wasCancelled { handle.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let h = handle
            handle = nil
            lock.unlock()
            h?.cancel()
        }

        func onUpdate(value: String) { continuation.yield(Data(value.utf8)) }

        func onError(message: String, value: String?) {
            let error: ClientError = value.map { .ConvexError(data: $0) } ?? .ServerError(msg: message)
            continuation.finish(throwing: ConvexMobileTransport.map(error))
        }
    }

    private final class SocketWatcher: WebSocketStateSubscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var connected = false
        private var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]

        func onStateChange(state: WebSocketState) {
            lock.lock()
            connected = state == .connected
            let value = connected
            let all = Array(listeners.values)
            lock.unlock()
            for l in all { l.yield(value) }
        }

        func stream() -> AsyncStream<Bool> {
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            lock.lock()
            listeners[id] = continuation
            let value = connected
            lock.unlock()
            continuation.yield(value)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.listeners[id] = nil
                self.lock.unlock()
            }
            return stream
        }
    }
}
