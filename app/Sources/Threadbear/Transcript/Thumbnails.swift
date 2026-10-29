import AppKit
import ImageIO
import Quartz

/// Decodes image thumbnails off the main thread at the size they're drawn,
/// and keeps them in an `NSCache`.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        // Thumbnails are decoded at drawn size, about 0.3 MB each; 24 MB
        // covers several screens of images. More only grows the footprint.
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private func key(_ path: String, _ pixels: Int) -> NSString { "\(path)|\(pixels)" as NSString }

    func cached(path: String, maxPixels: Int) -> CGImage? {
        cache.object(forKey: key(path, maxPixels))?.image
    }

    /// Calls back on the main thread; immediately if it's cached.
    func load(path: String, maxPixels: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        let cacheKey = key(path, maxPixels)
        if let hit = cache.object(forKey: cacheKey) {
            MainActor.assumeIsolated { completion(hit.image) }
            return
        }
        queue.addOperation { [cache] in
            let image = Self.decode(path: path, maxPixels: maxPixels)
            if let image {
                cache.setObject(CGImageBox(image), forKey: cacheKey, cost: image.bytesPerRow * image.height)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(image) }
            }
        }
    }

    static func decode(path: String, maxPixels: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Shows images in Quick Look. The transcript table forwards the panel's
/// responder-chain calls here.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var urls: [URL] = []
    private(set) var isActive = false

    func show(paths: [String], index: Int, from view: NSView) {
        urls = paths.map { URL(fileURLWithPath: $0) }
        if let table = sequence(first: view, next: { $0.superview }).first(where: { $0 is TranscriptTableView }) {
            view.window?.makeFirstResponder(table)
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.currentPreviewItemIndex = min(max(0, index), max(0, urls.count - 1))
    }

    func begin(_ panel: QLPreviewPanel) {
        isActive = true
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        isActive = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

/// Thumbnails laid out from precomputed frames, drawn as layers. Click one
/// to open it in Quick Look.
final class ImageGridView: NSView {
    private var paths: [String] = []
    private var frames: [NSRect] = []
    private var tiles: [CALayer] = []
    /// Set for another runner's thread ("bruce"): the pictures are files on
    /// that Mac, so each tile says so quietly instead of loading.
    var awayName: String?
    private var awayLabels: [CATextLayer] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(paths: [String], frames: [NSRect]) {
        self.paths = paths
        self.frames = frames
        while tiles.count < frames.count {
            let tile = CALayer()
            tile.cornerRadius = zoomed(8)
            tile.cornerCurve = .continuous
            tile.masksToBounds = true
            tile.borderWidth = 0.5
            tile.contentsGravity = .resizeAspectFill
            layer?.addSublayer(tile)
            tiles.append(tile)
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in tiles.enumerated() {
            guard index < frames.count else {
                tile.isHidden = true
                continue
            }
            tile.isHidden = false
            tile.frame = frames[index]
            tile.borderColor = Theme.cardBorder.resolvedCGColor(for: self)
            // A faint placeholder while the thumbnail decodes, and no box
            // behind the image once it's there.
            let placeholder = Theme.codeBackground.resolvedCGColor(for: self)
            label(for: index, in: tile)
            if awayName != nil {
                tile.contents = nil
                tile.backgroundColor = placeholder
                tile.name = nil
                continue
            }
            let path = paths[index]
            let pixels = Int(max(frames[index].width, frames[index].height) * scale)
            if let image = ThumbnailLoader.shared.cached(path: path, maxPixels: pixels) {
                tile.contents = image
                tile.backgroundColor = nil
            } else {
                tile.contents = nil
                tile.backgroundColor = placeholder
                tile.name = path
                ThumbnailLoader.shared.load(path: path, maxPixels: pixels) { [weak tile] image in
                    guard let tile, tile.name == path else { return }
                    tile.contents = image
                    if image != nil { tile.backgroundColor = nil }
                }
            }
            tile.name = path
        }
        CATransaction.commit()
    }

    /// "On bruce" in the middle of a tile whose picture is on another
    /// Mac; hidden otherwise.
    private func label(for index: Int, in tile: CALayer) {
        while awayLabels.count <= index {
            let text = CATextLayer()
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = window?.backingScaleFactor ?? 2
            tile.addSublayer(text)
            awayLabels.append(text)
        }
        let text = awayLabels[index]
        if text.superlayer !== tile { tile.addSublayer(text) }
        guard let awayName else {
            text.isHidden = true
            return
        }
        let font = NSFont.systemFont(ofSize: TypeScale.work - 1)
        text.isHidden = false
        text.string = "On \(awayName)"
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = Theme.faintText.resolvedCGColor(for: self)
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        text.frame = NSRect(x: 4, y: (tile.bounds.height - height) / 2, width: max(0, tile.bounds.width - 8), height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colours don't follow appearance changes on their own.
        let border = Theme.cardBorder.resolvedCGColor(for: self)
        for tile in tiles { tile.borderColor = border }
        if awayName != nil, !frames.isEmpty { show(paths: paths, frames: frames) }
    }

    /// Drops the decoded images, for a cell the table has parked off screen.
    /// Layer contents hold their own copy of each image.
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in tiles {
            tile.contents = nil
            tile.name = nil
        }
        CATransaction.commit()
        paths = []
        frames = []
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Nothing here to look at or drag: the file is on the other Mac.
        if awayName != nil { return super.mouseDown(with: event) }
        if let index = frames.firstIndex(where: { $0.contains(point) }) {
            // Dragged, the picture goes out as the file itself (FileDrag).
            if FileDrag.isDrag(from: event) {
                FileDrag.begin(URL(fileURLWithPath: paths[index]), from: self, event: event)
                return
            }
            QuickLookCoordinator.shared.show(paths: paths, index: index, from: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        guard awayName == nil else { return }
        for frame in frames { addCursorRect(frame, cursor: .pointingHand) }
    }
}
