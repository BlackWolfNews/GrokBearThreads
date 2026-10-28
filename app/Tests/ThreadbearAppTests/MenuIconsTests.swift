import Foundation
import XCTest

/// Every item in a right-click menu has an icon, like the system's own
/// Copy and Paste beside them (Mike asked for it, 28 Oct). Checked in the
/// source: AppKit items made with `NSMenuItem(title:symbol:…)` or given an
/// image straight after, and in SwiftUI's `.contextMenu { }` blocks and the
/// shared menus (`struct …Menu: View`), a `Button("…")` or `Menu("…")`
/// with a written title needs `systemImage:`. Items built from data (a
/// project's name, a snooze preset) are left plain.
final class MenuIconsTests: XCTestCase {
    private func sources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ["app/Sources/Threadbear", "dock/Sources"].flatMap { folder -> [URL] in
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)!
            return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }

    /// The text from each `{` after a match to its closing `}`.
    private func blocks(in text: String, after pattern: String) throws -> [(offset: Int, body: Substring)] {
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let start = text.index(text.startIndex, offsetBy: match.range.location + match.range.length - 1)
            guard text[start] == "{" else { return nil }
            var depth = 0
            var index = start
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" { depth -= 1; if depth == 0 { break } }
                index = text.index(after: index)
            }
            return (match.range.location, text[start..<min(index, text.endIndex)])
        }
    }

    func testRightClickMenuItemsHaveIcons() throws {
        let literal = try NSRegularExpression(pattern: #"\b(Button|Menu)\((\"|[^)]*\?\s*\")"#)
        var found: [String] = []
        for file in sources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let menus = try blocks(in: text, after: #"\.contextMenu\s*\{"#) + blocks(in: text, after: #"struct \w*Menu(Items)?: View \{"#)
            for (offset, body) in menus {
                for line in body.split(separator: "\n") {
                    let code = String(line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? line)
                    guard literal.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil, !code.contains("systemImage:") else { continue }
                    let lineNumber = text.prefix(offset).filter { $0 == "\n" }.count + 1
                    found.append("\(file.lastPathComponent) (menu from line \(lineNumber)): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("NSMenuItem(title:") && !line.contains("symbol:") {
                let next = lines[index...].prefix(4).joined(separator: "\n")
                if !next.contains(".image = ") { found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertEqual(found, [], "give these menu items an icon: systemImage: (SwiftUI) or NSMenuItem(title:symbol:action:)")
    }
}
