import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThreadbearKit

/// A server that sends whatever a test says, a chunk at a time, and notes
/// how much it sent and whether the phone hung up.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Keep sending `chunk` until stopped, after `body`.
        var endless = false
    }
    nonisolated(unsafe) static var reply = Reply()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _sent = 0
    nonisolated(unsafe) private static var _stopped = false
    static var sent: Int { lock.withLock { _sent } }
    static var stopped: Bool { lock.withLock { _stopped } }
    static func reset(_ r: Reply) { lock.withLock { reply = r; _sent = 0; _stopped = false } }
    static let chunk = Data(repeating: 0x41, count: 4096)

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Thread.detachNewThread { [self] in
            func send(_ data: Data) -> Bool {
                if Self.stopped { return false }
                client?.urlProtocol(self, didLoad: data)
                Self.lock.withLock { Self._sent += data.count }
                return true
            }
            if !reply.body.isEmpty, !send(reply.body) { return }
            while reply.endless {
                guard send(Self.chunk) else { return }
                usleep(200)
                // A safety net, so a broken cap can't run the test machine out of memory.
                if Self.sent > 64 * 1024 * 1024 { break }
            }
            if !Self.stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { Self.lock.withLock { Self._stopped = true } }
}

/// Daybreak finding 8: a picture's address is any https URL an agent wrote,
/// so its server must not be able to make the phone read or decode without end.
@Suite(.serialized) struct PictureDownloadTests {
    static let url = URL(string: "https://pictures.example.com/a.png")!
    static let limit = 256 * 1024

    static func png(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The finding's first test, with no Content-Length: a body that never
    /// ends is cut off at the cap and the transfer cancelled, never read whole.
    @Test func anEndlessResponseIsCancelledAtTheCap() async throws {
        StubServer.reset(.init(endless: true))
        await #expect(throws: PictureDownloadError.tooLarge) {
            try await CappedDownload.data(from: Self.url, session: StubServer.session(), limit: Self.limit)
        }
        // Give the stop a moment to land on the server's thread.
        for _ in 0..<100 where !StubServer.stopped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(StubServer.stopped)
        let sentAtStop = StubServer.sent
        try await Task.sleep(for: .milliseconds(100))
        #expect(StubServer.sent == sentAtStop, "still sending after the cancel")
        #expect(sentAtStop < 16 * 1024 * 1024)
    }

    /// And with a Content-Length over the cap: refused before the body.
    @Test func aContentLengthOverTheCapIsRefusedUnread() async throws {
        StubServer.reset(.init(headers: ["Content-Length": "\(500 * 1024 * 1024)"], endless: true))
        await #expect(throws: PictureDownloadError.tooLarge) {
            try await CappedDownload.data(from: Self.url, session: StubServer.session(), limit: Self.limit)
        }
        for _ in 0..<100 where !StubServer.stopped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(StubServer.stopped)
        #expect(StubServer.sent < Self.limit)
    }

    /// The finding's second test: an ordinary picture still comes down whole
    /// and decodes to the size the column asks for.
    @Test func aNormalPictureStillLoads() async throws {
        let png = try Self.png(width: 800, height: 600)
        StubServer.reset(.init(headers: ["Content-Length": "\(png.count)", "Content-Type": "image/png"], body: png))
        let data = try await CappedDownload.data(from: Self.url, session: StubServer.session(), limit: Self.limit)
        #expect(data == png)
        let source = try #require(try PictureSource.open(data))
        let image = try #require(PictureSource.thumbnail(source, maxSide: 400))
        #expect(image.width == 400 && image.height == 300)
    }

    /// Exactly at the cap is fine; one byte over isn't.
    @Test func theCapIsExact() async throws {
        StubServer.reset(.init(body: Data(repeating: 1, count: Self.limit)))
        #expect(try await CappedDownload.data(from: Self.url, session: StubServer.session(), limit: Self.limit).count == Self.limit)
        StubServer.reset(.init(body: Data(repeating: 1, count: Self.limit + 1)))
        await #expect(throws: PictureDownloadError.tooLarge) {
            try await CappedDownload.data(from: Self.url, session: StubServer.session(), limit: Self.limit)
        }
    }

    /// A small file whose header claims a huge picture is refused before
    /// ImageIO decodes any of it.
    @Test func aPixelBombIsRefusedFromItsHeader() throws {
        var png = try Self.png(width: 4, height: 4)
        // IHDR's width and height sit at bytes 16..<24: make it 30000 x 30000.
        let side = UInt32(30000).bigEndian
        withUnsafeBytes(of: side) { png.replaceSubrange(16..<20, with: $0); png.replaceSubrange(20..<24, with: $0) }
        #expect(png.count < 1024)
        #expect(throws: PictureDownloadError.tooManyPixels) { try PictureSource.open(png) }
        // A big but ordinary picture's header passes.
        #expect(try PictureSource.open(Self.png(width: 4000, height: 3000)) != nil)
    }

    @Test func aVideoIsntAnImage() throws {
        #expect(try PictureSource.open(Data("....ftypmp42 not a picture".utf8)) == nil)
    }
}
