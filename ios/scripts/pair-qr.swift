// Shows a pairing QR code for the phone, without the token ever being
// printed or going near the clipboard. Issues a phone token with
// `npx convex run tokens:issue`, makes the threadbear://pair link, draws it
// as a QR code into a temp PNG, opens it in Preview, and deletes the file
// ten minutes later. Point the iPhone's Camera at it.
//
//   swift ios/scripts/pair-qr.swift [--prod --url https://….convex.cloud] [--name iphone] [--days 90]
//
// Run from anywhere; it runs convex from the repo root.
import AppKit
import CoreImage

let args = Array(CommandLine.arguments.dropFirst())
let prod = args.contains("--prod")
func value(_ flag: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
    return args[i + 1]
}
let name = value("--name", prod ? "iphone" : "iphone-dev")
let days = Int(value("--days", "90")) ?? 90
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func run(_ command: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = command
    p.currentDirectoryURL = root
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.standardError
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { FileHandle.standardError.write("\(command[0..<3].joined(separator: " ")) failed\n".data(using: .utf8)!); exit(1) }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

// The deployment: --url, else CONVEX_URL from the repo's .env.local (dev).
var deployment = value("--url", "")
if deployment.isEmpty {
    let env = (try? String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8)) ?? ""
    let line = env.split(separator: "\n").first { $0.hasPrefix("CONVEX_URL=") } ?? ""
    deployment = String(line.dropFirst("CONVEX_URL=".count)).components(separatedBy: " ").first ?? ""
}
if prod && !args.contains("--url") {
    FileHandle.standardError.write("With --prod, pass --url <https://….convex.cloud> too.\n".data(using: .utf8)!)
    exit(1)
}
guard !deployment.isEmpty else { FileHandle.standardError.write("No CONVEX_URL in .env.local\n".data(using: .utf8)!); exit(1) }

var issue = ["npx", "convex", "run", "tokens:issue", "{\"name\":\"\(name)\",\"days\":\(days)}"]
if prod { issue.append("--prod") }
let output = run(issue)
guard let json = output.range(of: #"\{[\s\S]*\}"#, options: .regularExpression).map({ String(output[$0]) }),
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let token = object["token"] as? String else {
    FileHandle.standardError.write("Couldn't read the token from tokens:issue\n".data(using: .utf8)!)
    exit(1)
}

var link = URLComponents()
link.scheme = "threadbear"
link.host = "pair"
link.queryItems = [.init(name: "url", value: deployment), .init(name: "token", value: token)]

let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(link.url!.absoluteString.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let rep = NSBitmapImageRep(ciImage: qr)
let file = FileManager.default.temporaryDirectory.appendingPathComponent("threadbear-pair-\(UUID().uuidString.prefix(6)).png")
try! rep.representation(using: .png, properties: [:])!.write(to: file)
// Readable by Mike only.
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
NSWorkspace.shared.open(file)
print("Showing the pairing QR for \"\(name)\" (\(prod ? "prod" : "dev"), expires in \(days) days). Scan it with the iPhone Camera.")
print("The image deletes itself in 10 minutes. Revoke with: npx convex run tokens:revoke '{\"name\":\"\(name)\"}'\(prod ? " --prod" : "")")
// Delete later from a detached shell, so this script can return now.
let cleanup = Process()
cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
cleanup.arguments = ["-c", "(sleep 600; rm -f '\(file.path)') >/dev/null 2>&1 &"]
try? cleanup.run()
cleanup.waitUntilExit()
