import AppKit

/// The bear: Threadbear's mascot, a set of PNG sprites in the bundle's
/// Contents/Resources/Sprites (generated images, see
/// docs/threadbear-design/README.md; build-app.sh and dev-app.sh copy them
/// in). One bear for the app, not one per thread. Each pose is read once
/// and kept; a build that isn't a bundle (swift test, a bare binary) has no
/// sprites and gets nil, and whoever asked falls back to what it showed
/// before the bear.
enum Bear {
    enum Pose: String, CaseIterable {
        case sit, wave, sleep, patch, dizzy, cub
    }

    /// The working line's bear, in points. A touch bigger than a 16 pt tool
    /// icon so it reads as a character, not a glyph.
    static var workingSide: CGFloat { TypeScale.scaled(26) }

    private static var cache: [Pose: NSImage?] = [:]

    @MainActor
    static func image(_ pose: Pose) -> NSImage? {
        if let cached = cache[pose] { return cached }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Sprites/\(pose.rawValue).png")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        // Template off: these are full-colour pictures, not symbols.
        image?.isTemplate = false
        cache[pose] = image
        return image
    }
}
