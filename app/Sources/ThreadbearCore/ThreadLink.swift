import Foundation

/// `threadbear://thread/<id>`: a link that brings a thread up in the Mac
/// app. BrowserBear's "Open thread" pill on an agent's Chrome tab opens one
/// (with `open`), so the thread shows in the app rather than on the website.
public enum ThreadLink {
    public static let scheme = "threadbear"

    public static func url(threadId: String) -> URL? {
        URL(string: "\(scheme)://thread/\(threadId)")
    }

    /// The thread a link points at, or nil for any other link (the phone's
    /// `threadbear://pair` among them).
    public static func threadId(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "thread" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        // Thread ids are UUIDs and the like: nothing that could be a path.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }
}
