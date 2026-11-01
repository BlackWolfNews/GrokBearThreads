import XCTest
@testable import ThreadbearCore

final class HangSampleTests: XCTestCase {
    /// Cut down from a real `sample` of the app, with a branch at each of the
    /// places the walk could wander off the heaviest path.
    private let stuck = """
    Analysis of sampling Threadbear (pid 64764) every 1 millisecond
    Path:            /Users/USER/*/Threadbear.app/Contents/MacOS/Threadbear

    Call graph:
        1513 Thread_41679326   DispatchQueue_1: com.apple.main-thread  (serial)
        + 1497 start  (in dyld) + 6992  [0x1890984e4]
        + ! 1497 main  (in Threadbear) + 64  [0x1042b1ab0]  ThreadbearApp.swift:0
        + !   1497 _DPSNextEvent  (in AppKit) + 576  [0x18d956084]
        + !     1353 __CFRunLoopRun  (in CoreFoundation) + 820  [0x18951f884]
        + !     : 830 __CFRunLoopDoSources0  (in CoreFoundation) + 232  [0x189520c60]
        + !     : | 830 static Files.load(_:)  (in Threadbear) + 12  [0x1042b1000]  Files.swift:12
        + !     : |   830 stat  (in libsystem_kernel.dylib) + 8  [0x18941fc34]
        + !     : 352 __CFRunLoopRun  (in CoreFoundation) + 1188  [0x18951f9f4]
        + !     144 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x189521108]
        + 16 ???  (in <unknown binary>)  [0x10000]
        1513 Thread_41679408
        + 1513 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x189461b78]
    """

    private let idle = """
    Call graph:
        1513 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 1513 main  (in Threadbear) + 64  [0x1042b1ab0]  ThreadbearApp.swift:0
        + ! 1513 _DPSNextEvent  (in AppKit) + 576  [0x18d956084]
        + !   1513 __CFRunLoopRun  (in CoreFoundation) + 1188  [0x18951f9f4]
        + !   : 1513 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x189521108]
        + !   : | 1513 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x18941fc34]
    """

    func testFollowsTheHeaviestPathAndStopsAtTheFirstSibling() {
        XCTAssertEqual(HangSample.heaviestMainThreadPath(stuck), [
            "start (in dyld)",
            "main (in Threadbear)",
            "_DPSNextEvent (in AppKit)",
            "__CFRunLoopRun (in CoreFoundation)",
            "__CFRunLoopDoSources0 (in CoreFoundation)",
            "static Files.load(_:) (in Threadbear)",
            "stat (in libsystem_kernel.dylib)",
        ])
    }

    func testNamesTheDeepestFrameInTheAppsOwnCode() {
        let path = HangSample.heaviestMainThreadPath(stuck)
        XCTAssertEqual(HangSample.deepestAppFrame(path), "static Files.load(_:) (in Threadbear)")
    }

    func testMainAloneIsntAName() {
        XCTAssertNil(HangSample.deepestAppFrame(HangSample.heaviestMainThreadPath(idle)))
    }

    func testAMainThreadWaitingForEventsIsIdle() {
        XCTAssertTrue(HangSample.isIdle(HangSample.heaviestMainThreadPath(idle)))
        XCTAssertFalse(HangSample.isIdle(HangSample.heaviestMainThreadPath(stuck)))
    }

    func testPathsInTheFileNeverReachTheResult() {
        XCTAssertFalse(HangSample.heaviestMainThreadPath(stuck).joined().contains("/Users"))
    }

    func testTextWithoutAMainThreadHasNoPath() {
        XCTAssertEqual(HangSample.heaviestMainThreadPath("Call graph:\n    5 Thread_1\n"), [])
        XCTAssertEqual(HangSample.heaviestMainThreadPath(""), [])
    }

    func testSampleIsKeptAwayFromWhatMacOSAsksAbout() {
        let profile = HangSample.sandboxProfile(home: "/Users/me")
        for path in ["/Volumes", "/Users/me/Downloads", "/Users/me/Documents", "/Users/me/Desktop", "/Users/me/Library/Mobile Documents"] {
            XCTAssertTrue(profile.contains("(subpath \"\(path)\")"), path)
        }
    }

    /// The real thing: the profile has to parse, and sample still has to read
    /// a stack from inside it, or HangWatch would quietly stop finding hangs.
    func testSampleStillWorksInTheSandbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/bin/sleep")
        target.arguments = ["20"]
        try target.run()
        defer { target.terminate() }
        let file = dir.appendingPathComponent("s.sample")
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        sample.arguments = ["-p", HangSample.sandboxProfile(home: NSHomeDirectory()), "/usr/bin/sample", String(target.processIdentifier), "1", "-file", file.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try sample.run()
        sample.waitUntilExit()
        XCTAssertEqual(sample.terminationStatus, 0)
        XCTAssertFalse(HangSample.heaviestMainThreadPath(try String(contentsOf: file, encoding: .utf8)).isEmpty)
    }
}
