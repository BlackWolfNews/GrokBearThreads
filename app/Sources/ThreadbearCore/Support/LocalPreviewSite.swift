import CryptoKit
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
/// - it's the page itself, or a passive asset, one of `assetExtensions`:
///   styles, pictures, fonts, sound and video. Never another page, a script,
///   SVG (which can carry script), `.json`, `.txt`, `.env`, keys...;
/// - a page or stylesheet served before names it in markup or CSS (the page
///   itself always): `src`, `href`, `srcset`, `poster`, a style's `url()`,
///   a stylesheet's `url()` and `@import`. Never a string in a script.
///
/// The page can still name a file beside it in its markup and read it, so
/// the preview's web view lets nothing out either (WebPanelPool and
/// LocalPreviewSchemeHandler: no network, no navigating away, no windows,
/// no downloads), and what it reads stays on screen.
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

    /// What a page can pull in besides itself: passive files only. A
    /// sibling page or script named by the page (an iframe, a script src)
    /// would let it read whatever that names in turn (verify-fix, Nov 2026),
    /// so a preview of a several-file HTML or JS project shows its main page
    /// alone. The page's own scripts don't run at all (WebPanelPool).
    public static let assetExtensions: Set<String> = [
        "css",
        "png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp", "heic",
        "woff", "woff2", "ttf", "otf",
        "mp4", "webm", "m4v", "mov", "mp3", "m4a", "wav", "ogg",
    ]
    /// What can be the page.
    public static let pageExtensions: Set<String> = ["html", "htm"]
    /// Files read for links: the page and stylesheets. Not scripts, which can
    /// build any name they like at run time anyway.
    static let scannedExtensions: Set<String> = ["html", "htm", "css"]
    /// Bigger than any page or picture a preview needs.
    public static let maxBytes = 64 * 1024 * 1024

    /// The folder is the file's own (its symlinks followed); the page itself
    /// is held to the same rules as everything else when it's served.
    /// `pageDigest`: the page's bytes Mike allowed to run scripts (SHA-256,
    /// hex). Its view runs JavaScript, so the page is served only while its
    /// bytes still match: an agent rewriting it after the click, or the
    /// page reloading itself after a rewrite, gets nothing (6 Nov 2026).
    public init?(file: URL, pageDigest: String? = nil) {
        self.pageDigest = pageDigest
        let file = file.standardizedFileURL
        let page = file.lastPathComponent
        guard Self.pageExtensions.contains((page as NSString).pathExtension.lowercased()), !page.hasPrefix(".") else { return nil }
        root = file.deletingLastPathComponent().resolvingSymlinksInPath()
        // Held open for the site's life: every read starts here, so the
        // folder being moved or swapped for a link later changes nothing.
        rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        self.page = page
        allowed = [page]
    }

    private let rootFD: Int32
    public let pageDigest: String?

    deinit { close(rootFD) }

    /// The bytes and MIME type for `path` (from the folder, as in the URL
    /// the page asked for), or nil when it isn't one the page may read.
    public func serve(_ path: String) -> (data: Data, mimeType: String)? {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let parts = Self.safeParts(path) else { return nil }
        let relative = parts.joined(separator: "/")
        let ext = (relative as NSString).pathExtension.lowercased()
        // The page itself, or a passive asset something served has named.
        guard relative == page || Self.assetExtensions.contains(ext) && lock.withLock({ allowed.contains(relative) }) else { return nil }
        guard let data = Self.read(parts, under: rootFD, maxBytes: Self.maxBytes) else { return nil }
        if relative == page, let pageDigest, Self.digest(data) != pageDigest { return nil }
        if Self.scannedExtensions.contains(ext), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let dir = (relative as NSString).deletingLastPathComponent
            let found = (ext == "css" ? Self.cssReferences(in: text) : Self.htmlReferences(in: text)).compactMap { Self.resolve($0, from: dir) }
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
    /// Also nil for one with a control character, a backslash or a `%`:
    /// `openat` stops at a NUL, so `credentials.json\0.html` passed the
    /// extension check as a page and opened `credentials.json` (Codex's
    /// second review), and a `%` left after decoding means it was encoded
    /// twice, which no real asset name needs.
    static func safeParts(_ path: String) -> [String]? {
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "\\" || $0 == "%" }) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
        return parts
    }

    /// What a page's markup names: `src`, `href`, `poster` and `data`
    /// attributes, each part of a `srcset`, and `url()` and `@import` in its
    /// style attributes and `<style>` blocks. Scripts' contents are taken
    /// out first, so nothing a script says counts.
    static func htmlReferences(in text: String) -> [String] {
        let markup = text.replacingOccurrences(of: #"(<script\b[^>]*>)[\s\S]*?(</script\s*>)"#, with: "$1$2",
                                               options: [.regularExpression, .caseInsensitive])
        var out = matches(#"\b(?:src|href|poster|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, in: markup)
        for srcset in matches(#"\bsrcset\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, in: markup) {
            for piece in srcset.split(separator: ",") {
                if let first = piece.split(separator: " ").first { out.append(String(first)) }
            }
        }
        return out + cssReferences(in: markup)
    }

    /// What a stylesheet names: `url()` and `@import`.
    static func cssReferences(in text: String) -> [String] {
        matches(#"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"'\s]*))\s*\)"#, in: text)
            + matches(#"@import\s+(?:"([^"]*)"|'([^']*)')"#, in: text)
    }

    /// The first group that matched in each match of `pattern`.
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1..<match.numberOfRanges).lazy.compactMap { Range(match.range(at: $0), in: text) }.first
                .map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
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
        // Where a decoded NUL, control character or leftover `%` is refused.
        guard !stack.isEmpty, safeParts(stack.joined(separator: "/")) != nil else { return nil }
        return stack.joined(separator: "/")
    }

    /// Whether a page has scripts of its own, which the preview runs only
    /// once Mike says so for those exact bytes (PreviewScriptConsent): the
    /// pane asks rather than showing a page that draws itself as blank
    /// boxes (6 Nov 2026). The runner's `pin` tool tells the agent the same
    /// (runner/src/runner/highlights.ts). A `<script`, an `on...=` handler
    /// in a tag or a `javascript:` link anywhere counts, even in a comment:
    /// asking wrongly costs a bar, missing one looks broken. The runner's
    /// test is the same pattern.
    public static func hasScripts(_ html: Data) -> Bool {
        String(decoding: html.prefix(scriptScanBytes), as: UTF8.self)
            .range(of: scriptPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let scriptPattern = #"<script|<[^>]*\son[a-z]+\s*=|javascript:"#

    /// How much of a page `hasScripts` reads.
    public static let scriptScanBytes = 4 * 1024 * 1024

    /// SHA-256 of a page's bytes, hex: what a consent to run scripts is for.
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A page file read for the pane's bar: whether it has scripts, and the
    /// digest of what was read. Nil for anything but a regular file up to
    /// `maxBytes`. Opened without blocking and checked on the open file, so
    /// a FIFO named `.html` (or one swapped in) can't hang the caller.
    public static func scan(atPath path: String) -> (scripts: Bool, digest: String)? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxBytes,
              let data = try? handle.readToEnd() ?? Data(), data.count <= maxBytes else { return nil }
        return (hasScripts(data), digest(data))
    }
}
