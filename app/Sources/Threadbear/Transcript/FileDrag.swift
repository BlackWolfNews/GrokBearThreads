import AppKit

/// Dragging a file or link out of the app, onto X in Chrome, the Finder or
/// anything else that takes a drop: Mike wanted to post a clip without
/// opening the panel first (29 Oct). File links and paths in the
/// transcript, its picture tiles, Highlights' file rows and a picture or
/// video in the pane all start one here.
@MainActor
enum FileDrag {
    /// How far the mouse moves, in points, before a press is a drag
    /// rather than a click (about what the Finder waits for).
    static let threshold: CGFloat = 4

    /// Waits on a press to see whether it's a drag. True once the mouse
    /// has moved far enough; false when it's let go first, with that
    /// mouse-up left in the queue, so a view's own `mouseDown` can still
    /// see the click through.
    static func isDrag(from event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let start = event.locationInWindow
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                              inMode: .eventTracking, dequeue: false) else { return false }
            if next.type == .leftMouseUp { return false }
            _ = window.nextEvent(matching: [.leftMouseDragged])
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= threshold { return true }
        }
    }

    /// What's put on the pasteboard: a file as a file URL (what the
    /// Finder gives, so a site's upload box takes the file itself), a web
    /// link as a URL and its text. Nil for a file that isn't there.
    static func writer(for url: URL) -> NSPasteboardWriting? {
        if url.isFileURL {
            // A page's ?query isn't part of the file.
            let file = URL(fileURLWithPath: url.path)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file as NSURL
        }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        return item
    }

    /// Starts dragging `url` from `view`, its picture under the mouse.
    /// False when there's nothing to drag (the file's gone).
    @discardableResult
    static func begin(_ url: URL, from view: NSView, event: NSEvent) -> Bool {
        guard let writer = writer(for: url) else { return false }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = picture(for: url)
        let point = view.convert(event.locationInWindow, from: nil)
        let size = image.size
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), contents: image)
        view.beginDraggingSession(with: [item], event: event, source: Source.shared)
        return true
    }

    /// A small copy of a picture (ImageIO's thumbnail, quick enough to make
    /// on the spot), else the file's icon (a video's too); a link symbol
    /// for a web link.
    private static func picture(for url: URL) -> NSImage {
        let side: CGFloat = 64
        guard url.isFileURL else {
            let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
            return symbol.withSymbolConfiguration(.init(pointSize: 28, weight: .regular)) ?? symbol
        }
        let path = url.path
        if let thumbnail = ThumbnailLoader.decode(path: path, maxPixels: 192) {
            let scale = side * 1.5 / CGFloat(max(thumbnail.width, thumbnail.height, 1))
            return NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width) * scale,
                                                            height: CGFloat(thumbnail.height) * scale))
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    /// Copy only: a drop never moves or deletes the file.
    final class Source: NSObject, NSDraggingSource {
        static let shared = Source()

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
