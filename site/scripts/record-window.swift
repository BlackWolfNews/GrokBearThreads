// Records one window to a video file with ScreenCaptureKit, for the site's hero clips
// (scripts/clips.mjs). That window and anything its app draws over it (menus, pickers), no
// cursor, at the window's full pixel size.
//
//   swift scripts/record-window.swift <window id> <out.mov> <seconds>
//
// Stops after <seconds>, or earlier when a file named <out.mov>.stop appears. Needs Screen
// Recording permission for the shell running it.
import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

// ScreenCaptureKit needs a connection to the window server, which NSApplication sets up.
_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count == 4, let windowID = UInt32(args[1]), let seconds = Double(args[3]) else {
  FileHandle.standardError.write("usage: record-window.swift <window id> <out.mov> <seconds>\n".data(using: .utf8)!)
  exit(2)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) { print("finished"); exit(0) }
  func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) { print("failed: \(e)"); exit(1) }
  func stream(_ s: SCStream, didStopWithError e: Error) { print("stopped: \(e)"); exit(1) }
}

Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      print("no window \(windowID)"); exit(1)
    }
    // Everything the window's app draws (so its menus and pickers too), cropped to the window,
    // rather than the window alone, which leaves out the account picker's own little window.
    // Other apps' windows aren't drawn, so it doesn't matter what's in front of it.
    guard let app = window.owningApplication,
          let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else {
      print("no app or display for window \(windowID)"); exit(1)
    }
    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    config.sourceRect = CGRect(x: window.frame.minX - display.frame.minX, y: window.frame.minY - display.frame.minY,
                               width: window.frame.width, height: window.frame.height)
    config.width = Int(window.frame.width * scale)
    config.height = Int(window.frame.height * scale)
    config.backgroundColor = .clear
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    config.capturesAudio = false
    let delegate = Delegate()
    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
    let recConfig = SCRecordingOutputConfiguration()
    recConfig.outputURL = out
    recConfig.outputFileType = .mov
    recConfig.videoCodecType = .hevc
    let recording = SCRecordingOutput(configuration: recConfig, delegate: delegate)
    try stream.addRecordingOutput(recording)
    try await stream.startCapture()
    print("recording \(config.width)x\(config.height)")
    let stopFile = out.path + ".stop"
    let start = Date()
    while Date().timeIntervalSince(start) < seconds && !FileManager.default.fileExists(atPath: stopFile) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try? FileManager.default.removeItem(atPath: stopFile)
    try await stream.stopCapture()
    try stream.removeRecordingOutput(recording)
    // recordingOutputDidFinishRecording exits once the file is written.
    try await Task.sleep(nanoseconds: 5_000_000_000)
    print("timed out finishing"); exit(1)
  } catch {
    print("error: \(error)"); exit(1)
  }
}
RunLoop.main.run()
