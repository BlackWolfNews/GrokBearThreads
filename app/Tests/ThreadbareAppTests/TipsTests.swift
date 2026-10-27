import Foundation
import XCTest

/// SwiftUI's `.help` tooltips never came up in this app's window (macOS 26),
/// so every control uses `.tip` (Views/Tips.swift) and AppKit views use
/// `setTip`. This keeps a new `.help` or `toolTip` from going in, where it
/// would look set but show nothing.
final class TipsTests: XCTestCase {
    func testNoControlUsesHelpOrToolTip() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Threadbare")
        // The modifier, not a function that happens to be called help
        // (`ProjectMark.help(thread)`), and toolTip set on a view.
        let modifier = try NSRegularExpression(pattern: #"(^|[\s)}])\.help\(|\.toolTip\s*="#)
        var found: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if modifier.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "use .tip(...) (SwiftUI) or setTip(...) (AppKit) instead")
    }
}
