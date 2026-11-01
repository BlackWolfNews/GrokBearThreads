import Foundation

/// Reads the text `/usr/bin/sample` writes, for what HangWatch sends on: the
/// frames the main thread spent most of its time in, and nothing else of the
/// file. Symbols only: the file's image list has paths, and those stay here.
public enum HangSample {
    /// Runs `sample` through `sandbox-exec`, refused the places macOS would
    /// ask about. It hunts for debug symbols through Spotlight wherever that
    /// says they are, which on 31 Oct 2026 took the runner's copy of it deep
    /// into a Mac's external drive: a prompt left waiting there held up other
    /// apps on that drive for nearly nine hours (docs/protocol.md, "A dialog
    /// on a Mac's screen"). The stack it's after doesn't need those places.
    /// Same list as `sampleSandbox` in runner/src/frozen-cli.ts.
    public static func sandboxProfile(home: String) -> String {
        let paths = ["/Volumes", "/System/Volumes/Data/Volumes"]
            + ["Desktop", "Documents", "Downloads", "Dropbox", "Library/CloudStorage", "Library/Mobile Documents"].map { "\(home)/\($0)" }
        return "(version 1)(allow default)(deny file* \(paths.map { "(subpath \"\($0)\")" }.joined(separator: " ")))"
    }

    /// The main thread's heaviest path, outermost frame first, each as
    /// "symbol (in Image)". Empty when the text has no main thread.
    ///
    /// The call graph is a tree with each frame's children sorted heaviest
    /// first, so the heaviest path is the run of lines from the thread's own
    /// that keeps getting deeper. The first line that doesn't is a sibling.
    public static func heaviestMainThreadPath(_ text: String) -> [String] {
        var path: [String] = []
        var depth: Int?
        var inGraph = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inGraph {
                inGraph = line.hasPrefix("Call graph:")
                continue
            }
            guard let current = depth else {
                if line.contains("com.apple.main-thread") { depth = prefixLength(line) }
                continue
            }
            let lineDepth = prefixLength(line)
            guard lineDepth > current, let frame = frame(line) else { break }
            path.append(frame)
            depth = lineDepth
        }
        return path
    }

    /// The main thread only waiting for its next event: nothing was stuck when
    /// the sample ran. A stall that was over by then, or App Nap holding back
    /// the beat HangWatch listens for.
    public static func isIdle(_ path: [String]) -> Bool {
        path.contains { $0.hasPrefix("_DPSNextEvent") }
            && path.contains { $0.hasPrefix("__CFRunLoopServiceMachPort") }
            && !path.contains { $0.hasPrefix("__CFRunLoopDoSource") || $0.hasPrefix("__CFRunLoopDoObservers") || $0.hasPrefix("__CFRunLoopDoTimers") || $0.hasPrefix("_dispatch_main_queue") }
    }

    /// The deepest frame in the app's own code: the name a report goes by, as
    /// the frame at the very top is usually AppKit's or the kernel's.
    public static func deepestAppFrame(_ path: [String], image: String = "Threadbear") -> String? {
        // `main` is always there, and says nothing.
        path.last { $0.hasSuffix("(in \(image))") && !$0.hasPrefix("main ") }
    }

    /// Everything before the sample count: spaces and the tree's + ! : | marks.
    private static func prefixLength(_ line: Substring) -> Int {
        line.prefix { " +!:|".contains($0) }.count
    }

    /// "1497 main  (in Threadbear) + 64  [0x1042b1ab0]  ThreadbearApp.swift:0"
    /// to "main (in Threadbear)".
    private static func frame(_ line: Substring) -> String? {
        let body = line.drop { " +!:|".contains($0) }
        guard let space = body.firstIndex(of: " "), Int(body[..<space]) != nil else { return nil }
        var symbol = String(body[body.index(after: space)...])
        if let end = symbol.range(of: #"\s+\+ \d+\s+\[0x"#, options: .regularExpression) ?? symbol.range(of: #"\s+\[0x"#, options: .regularExpression) {
            symbol = String(symbol[..<end.lowerBound])
        }
        return symbol.replacingOccurrences(of: "  (in ", with: " (in ")
    }
}
