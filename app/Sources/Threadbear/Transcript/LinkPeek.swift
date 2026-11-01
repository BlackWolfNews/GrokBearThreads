import AppKit
import QuickLookThumbnailing
import SwiftUI
import ThreadbearCore
import UniformTypeIdentifiers

/// Where a link in the transcript goes, for its hover card: Mike wanted
/// to "quickly peek at what it wanted, then click it" (29 Oct), from a
/// link in a message or an asks card's link button alike. Text links are
/// found from their `.link`; a button carries one of these as `.tbPeek`,
/// as its run is an action, not a link. A class, so the attribute value
/// compares and copies like the rest of an attributed string's values.
final class LinkPeek: NSObject {
    /// A web page, or a file URL with `~` already expanded.
    let url: URL
    /// The words the link is on, or the button's title.
    let title: String?
    /// A picture's chip: the card is just the picture, as its file name
    /// and the runner's media folder mean nothing to Mike.
    let pictureOnly: Bool

    init(url: URL, title: String?, pictureOnly: Bool = false) {
        self.url = url
        self.title = title
        self.pictureOnly = pictureOnly
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LinkPeek else { return false }
        return url == other.url && title == other.title && pictureOnly == other.pictureOnly
    }

    override var hash: Int { url.hashValue }
}

/// The card: a file's picture (pictures, PDFs, text and pages, the files
/// the pane shows) or icon, its name and folder; a page's title and
/// address. A click on the link still opens it where it opens now.
struct LinkPeekCard: View {
    let peek: LinkPeek
    @State private var picture: NSImage?

    /// The picture's box is a fixed size, so the window can be sized
    /// before the thumbnail has loaded.
    private static let pictureSize = CGSize(width: 276, height: 170)

    var body: some View {
        Group {
            if peek.pictureOnly, exists {
                pictureBox.padding(zoomed(6))
            } else {
                details
                    .padding(.horizontal, zoomed(12))
                    .padding(.vertical, zoomed(10))
            }
        }
        .frame(width: peek.pictureOnly && exists ? nil : zoomed(300), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadPicture() }
    }

    private var pictureBox: some View {
        ZStack {
            // No fill behind a chip's picture: alone in the card, its letterbox looks like a frame.
            RoundedRectangle(cornerRadius: zoomed(4)).fill(Color.primary.opacity(peek.pictureOnly ? 0 : 0.05))
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: zoomed(3)))
            }
        }
        .frame(width: zoomed(Self.pictureSize.width), height: zoomed(Self.pictureSize.height))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: zoomed(3)) {
            if isFile, Self.showsPicture(peek.url), exists {
                pictureBox.padding(.bottom, zoomed(5))
            }
            HStack(alignment: .top, spacing: zoomed(8)) {
                if isFile, !Self.showsPicture(peek.url) || !exists {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: peek.url.path))
                        .resizable().frame(width: zoomed(28), height: zoomed(28))
                }
                VStack(alignment: .leading, spacing: zoomed(3)) {
                    Text(title)
                        .font(.system(size: TypeScale.label, weight: .semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(exists ? "Click to open" : away.map { "On \($0). Click to open." } ?? "Not found on this Mac")
                .font(.system(size: TypeScale.small))
                .foregroundStyle(.tertiary)
                .padding(.top, zoomed(3))
        }
    }

    private var isFile: Bool { peek.url.isFileURL }
    /// "bruce", for a file in another runner's thread: a click fetches it.
    private var away: String? {
        guard isFile else { return nil }
        return MainActor.assumeIsolated { AppModel.shared.selectedThread.flatMap(AppModel.shared.runnerName(of:)) }
    }
    private var exists: Bool { !isFile || FileManager.default.fileExists(atPath: peek.url.path) }

    /// A file by its name; a page by the link's words, unless they're just
    /// the address again.
    private var title: String {
        if isFile { return peek.url.lastPathComponent }
        let address = HighlightText.address(peek.url.absoluteString)
        if let words = peek.title, !words.isEmpty, !address.hasPrefix(words), !peek.url.absoluteString.hasPrefix(words) { return words }
        return peek.url.host() ?? address
    }

    private var detail: String {
        isFile ? (peek.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            : HighlightText.address(peek.url.absoluteString)
    }

    /// The same kinds the pane previews (askAction): anything else, a
    /// folder or a .tandem project, gets its icon.
    static func showsPicture(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.image, .pdf, .text, .html].contains { type.conforms(to: $0) }
    }

    private func loadPicture() async {
        guard isFile, Self.showsPicture(peek.url), exists else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: zoomed(Self.pictureSize.width), height: zoomed(Self.pictureSize.height))
        if UTType(filenameExtension: peek.url.pathExtension)?.conforms(to: .image) == true {
            // The transcript's own decoder and cache, as for its thumbnails.
            let pixels = Int(max(size.width, size.height) * scale)
            picture = await withCheckedContinuation { done in
                ThumbnailLoader.shared.load(path: peek.url.path, maxPixels: pixels) { image in
                    done.resume(returning: image.map { NSImage(cgImage: $0, size: .zero) })
                }
            }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: peek.url, size: size, scale: scale, representationTypes: .thumbnail)
        picture = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
