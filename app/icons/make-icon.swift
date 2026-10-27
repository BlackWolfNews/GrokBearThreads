// Makes app/icons/threadbear.png from the mascot image.
//
//   swift app/icons/make-icon.swift docs/threadbear-design/mascot-a.png app/icons/threadbear.png
//
// The generated mascot comes as a rounded tile drawn on a dark square, with
// no alpha, so used as-is the Dock would show a dark square around the bear.
// This finds the tile (the first pixels that aren't the backdrop colour from
// each edge), scales it to the usual icon tile (824 of 1024 points, so it
// sits like every other icon) and clips it to a rounded square with
// transparent corners.
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

// The backdrop is whatever colour the top-left corner is; the tile is anything
// clearly different from it. The threshold is loose because the backdrop has
// a little grain, but tight enough to catch the tile's own dark brown edge.
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}
let backdrop = pixel(2, 2)
func isTile(_ x: Int, _ y: Int) -> Bool {
    let p = pixel(x, y)
    return abs(p.0 - backdrop.0) + abs(p.1 - backdrop.1) + abs(p.2 - backdrop.2) > 30
}
// Scan along the middle row and column: the tile's straight edges are there,
// clear of its rounded corners.
let midY = height / 2, midX = width / 2
var left = 0; while left < width && !isTile(left, midY) { left += 1 }
var right = width - 1; while right > 0 && !isTile(right, midY) { right -= 1 }
var top = 0; while top < height && !isTile(midX, top) { top += 1 }
var bottom = height - 1; while bottom > 0 && !isTile(midX, bottom) { bottom -= 1 }
// Pull the crop in a few pixels so the tile's own anti-aliased edge (which
// still has backdrop blended in) is outside the mask.
let inset = 6
// The tile is square; the two scans can disagree by a few pixels (the tile's
// soft shadow on one side), so take the shorter side from the top-left.
let tileSide = min(right - left, bottom - top) + 1 - inset * 2
let tile = CGRect(x: left + inset, y: top + inset, width: tileSide, height: tileSide)
print("tile in source (top-left origin): \(Int(tile.minX)),\(Int(tile.minY)) \(Int(tile.width))x\(Int(tile.height))")

// Bitmap coordinates above are top-left origin; CGImage cropping takes the same.
guard let cropped = cg.cropping(to: tile) else { exit(1) }

let canvas = 1024, side = 824, margin = (canvas - side) / 2
let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: margin, y: margin, width: tileSide, height: tileSide)
// macOS's icon corner radius is about 22.37% of the tile side.
let radius = CGFloat(side) * 0.2237
out.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.clip()
out.interpolationQuality = .high
out.draw(cropped, in: rect)

guard let result = out.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: result)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(canvas)x\(canvas)")
