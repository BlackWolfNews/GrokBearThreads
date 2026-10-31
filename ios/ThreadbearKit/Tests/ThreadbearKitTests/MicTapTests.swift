import Foundation
import Testing

/// A mic tap put on before the format has settled is an Objective-C
/// exception Swift can't catch: it crashed Ask on 29 Oct and the old reply dictation
/// on 30 Oct. The app's MicTap.install checks first, so every tap must go
/// through it. This reads the app's sources, as the Mac app's TipsTests do.
struct MicTapTests {
    @Test func everyMicTapGoesThroughMicTap() throws {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let needle = "installTap" + "("  // split, so this file doesn't match itself
        var offenders: [String] = []
        var sawMicTap = false
        let files = FileManager.default.enumerator(at: ios, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" && !file.path.contains("/.build/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "MicTap.swift" {
                sawMicTap = text.contains(needle)
                continue
            }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(needle) {
                offenders.append("\(file.path.replacingOccurrences(of: ios.path + "/", with: "")):\(i + 1)")
            }
        }
        #expect(sawMicTap, "MicTap.swift should be where the app's one tap is")
        #expect(offenders.isEmpty, "Put mic taps on with MicTap.install, which waits for the format to settle: \(offenders)")
    }
}
