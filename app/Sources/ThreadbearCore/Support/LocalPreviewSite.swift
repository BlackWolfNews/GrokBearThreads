import Foundation
import UniformTypeIdentifiers

/// What a local HTML file in the pane's preview may read: itself, and the
/// styles, scripts, pictures, fonts and media it names, in its own folder
/// or below. Nothing else beside it, so a page from a project (or one an
/// agent was talked into writing) can't read a `.env`, a key or a database
/// kept in the same folder. It was loaded with read access to its whole
/// folder until Daybreak finding 6 (Nov 2026).
///
/// The Mac app serves the page through a WKURLSchemeHandler
/// (LocalPreviewSchemeHandler) that asks `serve` for every request. A file
/// is served only when all of these hold:
/// - its path has no `..`, no empty part and no part starting with a dot;
/// - it's one of `assetExtensions` (no `.json`, `.txt`, `.env`, keys...);
/// - a page or stylesheet served before names it (the page itself always);
/// - it's reached from the folder without following a symlink anywhere on
///   the way, and is a regular file with one link, checked on the open file
///   it's then read from, so swapping it for a link after the check reads
///   nothing (Codex review).
public final class LocalPreviewSite: @unchecked Sendable {
    /// The page's folder, symlinks resolved.
    public let root: URL
    /// The page's path from `root`: its file name.
    public let page: String
    private let lock = NSLock()
    private var allowed: Set<String>

    /// What a page can pull in. Pages too, so a mockup's own links work.
    public static let assetExtensions: Set<String> = [
        "html", "htm", "css", "js", "mjs",
        "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "ico", "bmp", "heic",
        "woff", "woff2", "ttf", "otf",
        "mp4", "webm", "m4v", "mov", "mp3", "m4a", "wav", "ogg",
    ]
    /// Files read for links: pages, stylesheets and scripts.
    static let scannedExtensions: Set<String> = ["html", "htm", "css", "js", "mjs"]
    /// Bigger than any page or picture a preview needs.
    public static let maxBytes = 64 * 1024 * 1024

    /// The folder is the file's own (its symlinks followed); the page itself
    /// is held to the same rules as everything else when it's served.
    public init?(file: URL) {
        let file = file.standardizedFileURL
        let page = file.lastPathComponent
        guard Self.assetExtensions.contains((page as NSString).pathExtension.lowercased()), !page.hasPrefix(".") else { return nil }
        root = file.deletingLastPathComponent().resolvingSymlinksInPath()
        // Held open for the site's life: every read starts here, so the
        // folder being moved or swapped for a link later changes nothing.
        rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        self.page = page
        allowed = [page]
    }

    private let rootFD: Int32

    deinit { close(rootFD) }

    /// The bytes and MIME type for `path` (from the folder, as in the URL
    /// the page asked for), or nil when it isn't one the page may read.
    public func serve(_ path: String) -> (data: Data, mimeType: String)? {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let parts = Self.safeParts(path) else { return nil }
        let relative = parts.joined(separator: "/")
        let ext = (relative as NSString).pathExtension.lowercased()
        guard Self.assetExtensions.contains(ext), lock.withLock({ allowed.contains(relative) }) else { return nil }
        guard let data = Self.read(parts, under: rootFD, maxBytes: Self.maxBytes) else { return nil }
        if Self.scannedExtensions.contains(ext), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let dir = (relative as NSString).deletingLastPathComponent
            let found = Self.references(in: text).compactMap { Self.resolve($0, from: dir) }
            lock.withLock { allowed.formUnion(found) }
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return (data, mime)
    }

    /// The file at `parts` under the folder open as `rootFD`: each folder on
    /// the way and the file itself opened with O_NOFOLLOW, so a symlink
    /// anywhere refuses it (`logo.png` linked to the `.env` beside it, a
    /// folder linked elsewhere), then checked and read on that one open file.
    static func read(_ parts: [String], under rootFD: Int32, maxBytes: Int) -> Data? {
        guard let name = parts.last else { return nil }
        var dir = rootFD
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts.dropLast() {
            let fd = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            opened.append(fd)
            dir = fd
        }
        // O_NONBLOCK, so a FIFO named like a picture can't hang the open.
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              // A hard link is the same file as one somewhere else.
              info.st_nlink == 1,
              info.st_size <= maxBytes else { return nil }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue } else { return nil } }
            if n == 0 { break }
            out.append(buffer, count: n)
            // It grew after the check.
            if out.count > maxBytes { return nil }
        }
        return out
    }

    /// The path's parts, or nil for one with `..`, `.`, an empty part or a dotfile.
    static func safeParts(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        return parts
    }

    /// Every string in a page, stylesheet or script that could be a path:
    /// quoted strings, unquoted attribute values, `url(...)`, and each part
    /// of a `srcset`. Most aren't paths; `resolve` keeps the ones that are.
    static func references(in text: String) -> [String] {
        var out: [String] = []
        let patterns = [
            #""([^"<>\n]{1,1024})""#,
            #"'([^'<>\n]{1,1024})'"#,
            #"`([^`<>\n$]{1,1024})`"#,
            #"=\s*([^\s"'`<>=]{1,1024})"#,
            #"url\(\s*([^)"'\s]{1,1024})\s*\)"#,
        ]
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[r]).trimmingCharacters(in: .whitespaces)
                out.append(value)
                // srcset="a.png 1x, b.png 2x"
                if value.contains(",") || value.contains(" ") {
                    for piece in value.split(separator: ",") {
                        if let first = piece.split(separator: " ").first { out.append(String(first)) }
                    }
                }
            }
        }
        return out
    }

    /// `ref`, named in a file in `dir`, as a path from the folder: nil for
    /// anything with a scheme (`https:`, `data:`), a `//host`, or a path
    /// that climbs out of the folder or isn't an asset.
    static func resolve(_ ref: String, from dir: String) -> String? {
        var ref = ref
        if let cut = ref.firstIndex(where: { $0 == "?" || $0 == "#" }) { ref = String(ref[..<cut]) }
        guard !ref.isEmpty, !ref.hasPrefix("//"), ref.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil,
              let decoded = ref.removingPercentEncoding,
              Self.assetExtensions.contains((decoded as NSString).pathExtension.lowercased()) else { return nil }
        var stack: [String] = decoded.hasPrefix("/") ? [] : dir.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                // Above the folder: never.
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: stack.append(String(part))
            }
        }
        guard !stack.isEmpty, safeParts(stack.joined(separator: "/")) != nil else { return nil }
        return stack.joined(separator: "/")
    }
}
