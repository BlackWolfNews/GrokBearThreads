// Makes the iPhone icon from the mascot image, the same bear as the Mac's.
//
//   swift ios/scripts/make-icon.swift docs/threadbear-design/mascot-a.png ios/Threadbear/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// The mascot is a rounded tile on a dark square. iOS wants a full-bleed,
// opaque square and rounds the corners itself, so this finds the tile (as
// app/icons/make-icon.swift does), crops to it and fills the canvas. The
// tile's own corners are rounder than nothing but tighter than iOS's mask,
// so the little bit of backdrop left in them is masked away on the phone.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make-icon.swift <mascot.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let width = cg.width, height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}
let backdrop = pixel(2, 2)
func isTile(_ x: Int, _ y: Int) -> Bool {
    let p = pixel(x, y)
    return abs(p.0 - backdrop.0) + abs(p.1 - backdrop.1) + abs(p.2 - backdrop.2) > 30
}
let midY = height / 2, midX = width / 2
var left = 0; while left < width && !isTile(left, midY) { left += 1 }
var right = width - 1; while right > 0 && !isTile(right, midY) { right -= 1 }
var top = 0; while top < height && !isTile(midX, top) { top += 1 }
var bottom = height - 1; while bottom > 0 && !isTile(midX, bottom) { bottom -= 1 }
let inset = 6
let side = min(right - left, bottom - top) + 1 - inset * 2
guard let cropped = cg.cropping(to: CGRect(x: left + inset, y: top + inset, width: side, height: side)) else { exit(1) }

let canvas = 1024
// No alpha: the App Store refuses icons with any.
let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
out.interpolationQuality = .high
out.draw(cropped, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) from a \(side) px tile")
