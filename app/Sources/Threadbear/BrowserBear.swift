import Foundation

/// BrowserBear (github.com/mikecann/browserbear) lets agents use Mike's real
/// Chrome, in a window of its own. When an agent asks him to sign in on a
/// page it has open there and gives the page as a link, opening the link
/// made a second tab of it in his main window while the agent's sat unseen
/// on the other screen (Qantas, 30 Oct 2026). So a web link first asks
/// BrowserBear to hand over an agent tab already on that page: it moves into
/// his window and comes to the front.
enum BrowserBear {
    static var socket: String {
        let home = ProcessInfo.processInfo.environment["BROWSERBEAR_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/BrowserBear")
        return (home as NSString).appendingPathComponent("browserbear.sock")
    }

    /// True when an agent's tab was on `url` and is now in front of Mike.
    /// False straight away without BrowserBear, and after 4 s at most when
    /// it doesn't answer: a tab an agent opened is found at once, but ruling
    /// one out means listing Chrome's tabs, which takes seconds while
    /// BrowserBear's extension wakes up (2 s was too short, 30 Oct).
    static func handoff(_ url: URL) async -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              FileManager.default.fileExists(atPath: socket) else { return false }
        let path = socket
        return await Task.detached { request(path: path, cmd: "handoff", args: ["tab": url.absoluteString]) }.value
    }

    /// One `{id, cmd, args}` line out, one `{id, ok, ...}` line back.
    private static func request(path: String, cmd: String, args: [String: String]) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var wait = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0,
              var line = try? JSONSerialization.data(withJSONObject: ["id": 1, "cmd": cmd, "args": args]) else { return false }
        line.append(0x0A)
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == line.count else { return false }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return false }
            reply.append(contentsOf: buffer[0..<n])
        }
        let object = try? JSONSerialization.jsonObject(with: reply.prefix { $0 != 0x0A })
        return (object as? [String: Any])?["ok"] as? Bool == true
    }
}
