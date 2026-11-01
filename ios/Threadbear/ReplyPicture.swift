import ImageIO
import SwiftUI
import ThreadbearKit
import UIKit

extension EnvironmentValues {
    /// The open thread's pictures, for MarkdownText to find its images in.
    @Entry var threadPictures = ThreadPictures()
}

/// Pictures from file storage or the web. Their own cache on disk, as
/// URLCache.shared won't keep anything much bigger than half a megabyte, and
/// a picture shouldn't be fetched again each time it scrolls back into view.
actor PictureLoader {
    static let shared = PictureLoader()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Pictures")
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: folder)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
    /// By url and size, so the column's small copy and the full-screen one
    /// are kept apart.
    private let decoded = NSCache<NSString, UIImage>()

    /// The largest side's pixels decoded: a phone's column doesn't need all
    /// of a big PNG in memory. Nil for the whole picture.
    func image(_ url: URL, maxPixels: Int?) async throws -> UIImage {
        let key = "\(maxPixels ?? 0) \(url.absoluteString)" as NSString
        if let image = decoded.object(forKey: key) { return image }
        let (data, _) = try await session.data(from: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw URLError(.cannotDecodeContentData) }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        if let maxPixels { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let image = UIImage(cgImage: cg)
        decoded.setObject(image, forKey: key)
        return image
    }
}

/// A picture in a reply: as wide as the column at most, no taller than a
/// good part of the screen and never blown up past its own size. Tap for
/// full screen. Its place is kept from the size the runner sent, so the
/// thread doesn't jump as it loads.
struct ReplyPicture: View {
    /// A page of text shouldn't be pushed off screen by one tall picture.
    static let maxHeight: CGFloat = 360
    static let maxPixels = 1400

    var url: URL
    var alt: String
    var width: Int?
    var height: Int?

    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullScreen = false

    private var size: CGSize? {
        if let image { return CGSize(width: image.size.width, height: image.size.height) }
        if let width, let height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        return nil
    }

    var body: some View {
        Group {
            if failed {
                PictureOnMac(alt: alt, note: "Couldn't load this picture")
            } else {
                Button { fullScreen = true } label: { picture }
                    .buttonStyle(.plain)
                    .disabled(image == nil)
                    .accessibilityLabel(alt.isEmpty ? "Picture" : alt)
                    .accessibilityHint("Shows it full screen")
            }
        }
        .task(id: url) { await load() }
        .fullScreenCover(isPresented: $fullScreen) {
            PictureViewer(url: url, alt: alt, preview: image)
        }
    }

    @ViewBuilder private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        PictureFit(pixels: size, maxHeight: Self.maxHeight) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high)
                } else {
                    Color(.secondarySystemBackground).overlay { ProgressView() }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func load() async {
        failed = false
        do {
            image = try await PictureLoader.shared.image(url, maxPixels: Self.maxPixels)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failed = true
        }
    }
}

/// Exactly the picture's shape, so its border and corners are the picture's,
/// not the column's. A Layout because aspectRatio and frame together leave a
/// tall picture in a box the column's width, or overflow when the height is
/// unbounded, as it is in a scroll view. Pixels count as 2x, so a small
/// diagram stays small and sharp while a big one fills the column.
private struct PictureFit: Layout {
    var pixels: CGSize?
    var maxHeight: CGFloat
    /// Under this a picture is too small to make out, or to tap.
    private let smallest: CGFloat = 120

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let pixels = pixels ?? CGSize(width: 2000, height: 1500)
        var natural = CGSize(width: pixels.width / 2, height: pixels.height / 2)
        if natural.width < smallest {
            natural = CGSize(width: smallest, height: natural.height * smallest / natural.width)
        }
        let fit = min(1, (proposal.width ?? natural.width) / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * fit).rounded(), height: (natural.height * fit).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// In place of a picture the phone can't have: it hasn't gone up yet, it's
/// too big, or it's from a thread too old to have been looked through.
struct PictureOnMac: View {
    var alt: String
    var note = "On your Mac"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if !alt.isEmpty { Text(alt).font(.subheadline) }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Full screen on black: pinch or double tap to zoom, drag about, share or
/// save from the top bar.
struct PictureViewer: View {
    var url: URL
    var alt: String
    var preview: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var full: UIImage?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image = full ?? preview {
                ZoomableImage(image: image).ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button { dismiss() } label: { barIcon("xmark") }
                    .accessibilityLabel("Close")
                Spacer()
                if let image = full ?? preview {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(alt.isEmpty ? "Picture" : alt, image: Image(uiImage: image))) {
                        barIcon("square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
            .padding(.horizontal)
        }
        .statusBarHidden()
        .task { full = try? await PictureLoader.shared.image(url, maxPixels: nil) }
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: Circle())
    }
}

/// UIScrollView for the zoom, which SwiftUI's gestures only come close to:
/// pinching about the fingers, the bounce at the limits, panning a zoomed
/// picture with the same drag.
private struct ZoomableImage: UIViewRepresentable {
    var image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FittingScrollView {
        let scroll = FittingScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: FittingScrollView, context: Context) {
        guard scroll.imageView.image !== image else { return }
        scroll.imageView.image = image
        scroll.setNeedsLayout()
    }

    final class FittingScrollView: UIScrollView {
        let imageView = UIImageView()
        private var fittedTo: CGSize = .zero
        private var fittedImage: UIImage?

        override func layoutSubviews() {
            super.layoutSubviews()
            // Fit once per size (a rotation) or picture, never mid-zoom.
            if fittedTo != bounds.size || fittedImage !== imageView.image {
                fittedTo = bounds.size
                fittedImage = imageView.image
                zoomScale = 1
                imageView.frame = fittedFrame()
                contentSize = imageView.frame.size
            }
            center()
        }

        private func fittedFrame() -> CGRect {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return bounds }
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            return CGRect(x: 0, y: 0, width: size.width * fit, height: size.height * fit)
        }

        /// Centred while smaller than the screen.
        func center() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? FittingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? FittingScrollView)?.center()
        }

        @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? FittingScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let at = tap.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
