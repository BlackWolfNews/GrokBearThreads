// Signs a browser in to the Threadbear website (docs/website.md) without the
// token ever being printed, copied or left on disk. Issues a phone token
// with `npx convex run tokens:issue` (so only someone logged in to the
// Convex team can do it) and puts it in the link's #fragment, which the
// page keeps in localStorage and wipes from the address bar. The fragment
// never reaches a server.
//
//   npm run web:sign-in                       Chrome on this Mac, prod site
//   npm run web:sign-in -- --qr               a QR code to scan on another device
//   npm run web:sign-in -- --dev              the dev deployment's site
//   npm run web:sign-in -- --local            Vite on localhost:5181 (dev data)
//   npm run web:sign-in -- --name web-work --days 30
//
// Revoke with: npx convex run tokens:revoke '{"name":"web-mac"}' --prod
import AppKit
import CoreImage

// The Sydney deployments (docs/convex-backend.md).
let prodURL = "https://opulent-moose-249.ap-southeast-2.convex.site"
let devURL = "https://earnest-puffin-640.ap-southeast-2.convex.site"

let args = Array(CommandLine.arguments.dropFirst())
let qr = args.contains("--qr")
let local = args.contains("--local")
let prod = !args.contains("--dev") && !local
func value(_ flag: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
    return args[i + 1]
}
let name = value("--name", qr ? "web-qr" : "web-mac") + (prod ? "" : "-dev")
let days = Int(value("--days", "90")) ?? 90
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let site = local ? "http://localhost:5181" : prod ? prodURL : devURL

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var issue = ["npx", "convex", "run", "tokens:issue", "{\"name\":\"\(name)\",\"days\":\(days)}"]
if prod { issue.append("--prod") }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = issue
p.currentDirectoryURL = root
let out = Pipe()
p.standardOutput = out
p.standardError = FileHandle.standardError
try! p.run()
let data = out.fileHandleForReading.readDataToEndOfFile()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fail("npx convex run tokens:issue failed") }
let output = String(decoding: data, as: UTF8.self)
guard let json = output.range(of: #"\{[\s\S]*\}"#, options: .regularExpression).map({ String(output[$0]) }),
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let token = object["token"] as? String else { fail("Couldn't read the token from tokens:issue") }

let link = "\(site)/#token=\(token)"

if qr {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(link.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("threadbear-web-\(UUID().uuidString.prefix(6)).png")
    try! NSBitmapImageRep(ciImage: image).representation(using: .png, properties: [:])!.write(to: file)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    NSWorkspace.shared.open(file)
    // Preview has the picture once it's open, so no copy of the token stays
    // on disk (same as ios/scripts/pair-qr.swift).
    Thread.sleep(forTimeInterval: 3)
    try? FileManager.default.removeItem(at: file)
    print("Showing a sign-in QR for \"\(name)\" (\(site), \(days) days). Scan it with the camera, then close Preview.")
} else {
    // Mike's browser is Chrome; fall back to the default browser if it's missing.
    let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    let url = URL(string: link)!
    let config = NSWorkspace.OpenConfiguration()
    let done = DispatchSemaphore(value: 0)
    if let chrome {
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: config) { _, _ in done.signal() }
    } else {
        NSWorkspace.shared.open(url, configuration: config) { _, _ in done.signal() }
    }
    done.wait()
    print("Opened \(site) signed in as \"\(name)\" (\(days) days).")
}
print("Revoke with: npx convex run tokens:revoke '{\"name\":\"\(name)\"}'\(prod ? " --prod" : "")")
