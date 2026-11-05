import Foundation
import XCTest

/// Every item in a right-click menu has an icon, like the system's own
/// Copy and Paste beside them (Mike asked for it, 28 Oct). Checked in the
/// source: AppKit items made with `NSMenuItem(title:symbol:…)` or given an
/// image straight after, and in SwiftUI's `.contextMenu { }` blocks and the
/// shared menus (`struct …Menu: View`), a `Button("…")` or `Menu("…")`
/// with a written title needs `systemImage:`.
///
/// That isn't enough to see them: macOS hides a SwiftUI menu's icons unless
/// `.labelStyle(.titleAndIcon)` is on its items (5 Nov; every one added on
/// 28 Oct was hidden). So the app's menus have to use `IconMenu` and
/// `.iconContextMenu`, which put it there.
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

    /// BearDock can't see the app's wrappers: its one shared menu, PanelMenu,
    /// sets the style itself.
    func testSwiftUIMenusShowTheirIcons() throws {
        let bare = try NSRegularExpression(pattern: #"(\.contextMenu\s*\{(?!\s*PanelMenu)|^\s*Menu\s*\{|^\s*Menu\(")"#, options: .anchorsMatchLines)
        var found: [String] = []
        for file in sources() where !["MenuItems.swift", "DemoApp.swift"].contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in bare.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let line = text.prefix(match.range.location).filter { $0 == "\n" }.count + 1
                found.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertEqual(found, [], "macOS hides these menus' icons: use IconMenu or .iconContextMenu")
    }

    func testRightClickMenuItemsHaveIcons() throws {
        let literal = try NSRegularExpression(pattern: #"\b(Button|Menu)\((\"|[^)]*\?\s*\")"#)
        var found: [String] = []
        for file in sources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let menus = try blocks(in: text, after: #"\.contextMenu\s*\{"#) + blocks(in: text, after: #"struct \w*Menu(Items)?: View \{"#)
                + blocks(in: text, after: #"IconMenu\s*\{"#) + blocks(in: text, after: #"\.iconContextMenu\s*\{"#)
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
