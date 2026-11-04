import Foundation

/// File paths agents write in inline code (`app/Sources/Foo.swift`,
/// `TranscriptLinkTests.swift`, `/tmp/a.txt:12`), which replies use far
/// more than markdown links. The renderer makes path-shaped code spans
/// links; which file one means is only worked out when it's clicked, from
/// the thread's folder and the files its tools read and changed, because
/// renders are cached by their text and files come and go.
public enum FilePathRefs {
    /// The link a path-shaped span carries until it's clicked.
    public static let scheme = "tbpath"

    public static func url(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.queryItems = [URLQueryItem(name: "p", value: text)]
        return components.url
    }

    /// The text a `url(for:)` link was made from.
    public static func text(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value
    }

    /// Endings that are web addresses far more often than files.
    private static let domainEndings: Set<String> = ["com", "org", "net", "io", "dev", "co", "ai", "au", "uk"]

    /// Whether inline code reads as a file path: no scheme, and either
    /// rooted (`/`, `~/`, `./`, `../`), or ending in a file name with an
    /// extension. Folders need the leading root or a slash in them. Single
    /// spaces are allowed where they can't be a command (`spacedPathOK`).
    public static func looksLikePath(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 400, !text.contains("://"),
              !text.contains("*"), !text.contains("<"), !text.contains("`") else { return false }
        let path = stripLine(splitQuery(text).path)
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil, !spacedPathOK(path) { return false }
        if path.hasPrefix("/") { return path.count > 1 }
        if path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") { return true }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isLetter || $0.isNumber }), ext.contains(where: \.isLetter),
              name.count > ext.count + 1 else {
            // `runner/src/` and the like: a folder inside the project.
            return path.hasSuffix("/") && path.dropLast().contains("/")
        }
        if !path.contains("/"), domainEndings.contains(ext.lowercased()) { return false }
        return true
    }

    /// Whether a path with spaces in it (`exports/Threadbear Launch.mp4`,
    /// `~/Library/Application Support`) is one, rather than a command in
    /// inline code (`open exports/a.mp4`, `./check.sh --app`, `tb land`).
    /// Single spaces only, and only after the first folder, so a command's
    /// first word can't be read as part of the path; no flags or shell
    /// punctuation; and a spaced last part needs an extension, as
    /// `runner/bin/tb land` is a command.
    static func spacedPathOK(_ path: String) -> Bool {
        guard path.contains(" "), path.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.subtracting(CharacterSet(charactersIn: " "))) == nil,
              !path.hasPrefix(" "), !path.hasSuffix(" "), !path.contains("  "),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: "|;$>\"'")) == nil, !path.contains("&&"),
              let slash = path.firstIndex(of: "/"), let space = path.firstIndex(of: " "), slash < space,
              !path.split(separator: " ").contains(where: { $0.hasPrefix("-") }) else { return false }
        let last = path.hasSuffix("/") ? "" : (path as NSString).lastPathComponent
        return !last.contains(" ") || !(last as NSString).pathExtension.isEmpty
    }

    /// `Foo.swift:12` or `Foo.swift:12:4` names the file, and a line in it.
    public static func stripLine(_ text: String) -> String {
        var path = Substring(text)
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":"), colon != path.startIndex else { break }
            let tail = path[path.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            path = path[..<colon]
        }
        return String(path)
    }

    /// `grow.html?clean&s=45` or `guide.md#links`: a file, with a query or
    /// fragment that's for the page (its own script reads `?clean`), not
    /// part of the file's name. Split at the first `?` or `#`.
    public static func splitQuery(_ text: String) -> (path: String, query: String?, fragment: String?) {
        guard let mark = text.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return (text, nil, nil) }
        let path = String(text[..<mark])
        let rest = text[text.index(after: mark)...]
        if text[mark] == "#" { return (path, nil, String(rest)) }
        guard let hash = rest.firstIndex(of: "#") else { return (path, String(rest), nil) }
        return (path, String(rest[..<hash]), String(rest[rest.index(after: hash)...]))
    }

    /// The file `text` names as a file URL, carrying any `?query` and
    /// `#fragment` so a page opens with them. A file whose own name has a
    /// `?` or `#` in it wins over reading that as a query.
    public static func fileLink(_ text: String, root: String?, known: [String], home: String = NSHomeDirectory(),
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                search: (String, String) -> String? = FilePathRefs.search) -> URL? {
        let parts = splitQuery(text)
        guard parts.query != nil || parts.fragment != nil, !parts.path.isEmpty else {
            return resolve(text, root: root, known: known, home: home, exists: exists, search: search).map(URL.init(fileURLWithPath:))
        }
        // The whole text as a name: no folder search for it, as the
        // split one gets that.
        if let path = resolve(text, root: root, known: known, home: home, exists: exists, search: { _, _ in nil }) {
            return URL(fileURLWithPath: path)
        }
        guard let path = resolve(parts.path, root: root, known: known, home: home, exists: exists, search: search) else { return nil }
        return withQuery(URL(fileURLWithPath: path), query: parts.query, fragment: parts.fragment)
    }

    /// `url` with a query and fragment as an agent wrote them. They're
    /// decoded first so `a%20b` isn't escaped twice.
    public static func withQuery(_ url: URL, query: String?, fragment: String?) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = query.map { $0.removingPercentEncoding ?? $0 }
        components.fragment = fragment.map { $0.removingPercentEncoding ?? $0 }
        return components.url ?? url
    }

    /// A page that goes straight on to `url`. macOS drops a file URL's
    /// query and fragment when it hands one to a browser, so a page's
    /// `?clean` is lost; opening this instead gets them there.
    public static func forwardingPage(to url: URL) -> String {
        // JSONEncoder escapes `/`, so nothing in the link can close the script.
        let target = (try? JSONEncoder().encode(url.absoluteString)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "<!doctype html><meta charset=\"utf-8\"><script>location.replace(\(target))</script>\n"
    }

    /// The file `text` names, if one exists: as written (with `~`), then
    /// from the thread's folder, then from what the thread's tools touched,
    /// most recent first: a path ending with it, or it beside a file they
    /// touched or inside a folder they `cd`-ed into.
    public static func resolve(_ text: String, root: String?, known: [String], home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                               search: (String, String) -> String? = FilePathRefs.search) -> String? {
        var path = stripLine(text)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("~/") { path = home + path.dropFirst() }
        if path.hasPrefix("/") { return exists(path) ? path : nil }
        func join(_ base: String) -> String {
            ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        if let root, exists(join(root)) { return join(root) }
        let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        for candidate in known.reversed() {
            if candidate == trimmed || candidate.hasSuffix("/" + trimmed), exists(candidate) { return candidate }
            for base in [candidate, (candidate as NSString).deletingLastPathComponent] where exists(join(base)) {
                return join(base)
            }
        }
        // Last, a look through those folders for it: agents name a file by
        // itself (`TranscriptLinkTests.swift`) once they've been in its repo.
        // Four folders at most, as it runs on the click.
        var searched: Set<String> = []
        let folders = ([root].compactMap { $0 } + known.reversed().map { exists($0 + "/.") ? $0 : ($0 as NSString).deletingLastPathComponent })
        for folder in folders where searched.count < 4 && searched.insert(folder).inserted {
            if let found = search(folder, trimmed) { return found }
        }
        return nil
    }

    /// Folders a search never goes into: built and fetched files, and big.
    private static let skipped: Set<String> = ["node_modules", ".build", ".git", "dist", "build", "DerivedData", "Pods", ".next"]

    /// The first file under `folder` whose path ends with `path`, looking
    /// at no more than a few thousand entries so a click stays quick.
    public static func search(_ folder: String, _ path: String) -> String? {
        let root = URL(fileURLWithPath: folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let name = (path as NSString).lastPathComponent
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20_000 { return nil }
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent == name else { continue }
            let found = url.path
            if found.hasSuffix("/" + path) { return found }
        }
        return nil
    }

    /// Absolute paths in a thread's tool calls, oldest first: the files
    /// they read and changed, and the folders commands `cd` into.
    public static func toolPaths(_ items: [TranscriptRow], home: String = NSHomeDirectory()) -> [String] {
        var paths: [String] = []
        for item in items {
            guard case .tool(let tool) = item.content, let input = tool.call?.input else { continue }
            for key in ["file_path", "notebook_path", "path"] {
                if let path = input[key]?.stringValue { paths.append(path) }
            }
            paths.append(contentsOf: tool.editedPaths)
            if let command = input["command"]?.stringValue { paths.append(contentsOf: cdTargets(command, home: home)) }
        }
        return paths.filter { $0.hasPrefix("/") }
    }

    nonisolated(unsafe) private static let cdPattern = try! NSRegularExpression(pattern: #"(?:^|&&|;|\|\||\()\s*cd\s+("[^"]+"|'[^']+'|[^\s;&|)]+)"#)

    /// The folders `cd` moves to in a shell command, made absolute.
    static func cdTargets(_ command: String, home: String) -> [String] {
        let ns = command as NSString
        return cdPattern.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var dir = ns.substring(with: match.range(at: 1))
            if dir.count >= 2, let first = dir.first, first == "\"" || first == "'" { dir = String(dir.dropFirst().dropLast()) }
            if dir == "~" { return home }
            if dir.hasPrefix("~/") { dir = home + dir.dropFirst() }
            return dir.hasPrefix("/") ? dir : nil
        }
    }
}
