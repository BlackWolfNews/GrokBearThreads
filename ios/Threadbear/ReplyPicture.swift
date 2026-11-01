import AVFoundation
import AVKit
import CryptoKit
import ImageIO
import SwiftUI
import ThreadbearKit
import UIKit
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// The open thread's pictures, for MarkdownText to find its images in.
    @Entry var threadPictures = ThreadPictures()
}

/// What a picture's address turned out to be. A class so a view can tell by
/// identity that it's already showing this one, without comparing the bytes.
nonisolated final class LoadedPicture: Sendable {
    enum Motion: Sendable {
        /// A GIF, or another format with several frames: the file's own bytes,
        /// which MovingImageView plays.
        case frames(Data)
        /// Plays full screen, from `file`.
        case video
    }

    /// A still picture, or the first frame of a moving one.
    let image: UIImage
    let motion: Motion?
    /// On disk for a moving picture, as sharing `image` would flatten it.
    let file: URL?

    init(image: UIImage, motion: Motion? = nil, file: URL? = nil) {
        self.image = image
        self.motion = motion
        self.file = file
    }

    var isVideo: Bool {
        if case .video = motion { true } else { false }
    }
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
    private let decoded = NSCache<NSString, LoadedPicture>()

    /// The largest side's pixels decoded: a phone's column doesn't need all
    /// of a big PNG in memory. Nil for the whole picture.
    func picture(_ url: URL, maxPixels: Int?) async throws -> LoadedPicture {
        let key = "\(maxPixels ?? 0) \(url.absoluteString)" as NSString
        if let picture = decoded.object(forKey: key) { return picture }
        let (data, _) = try await session.data(from: url)
        let picture = try await decode(data, url: url, maxPixels: maxPixels)
        decoded.setObject(picture, forKey: key)
        return picture
    }

    private func decode(_ data: Data, url: URL, maxPixels: Int?) async throws -> LoadedPicture {
        // An MP4 isn't an image source, or is one with no frames.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return try await decodeVideo(data, url: url, maxPixels: maxPixels)
        }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        if let maxPixels { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let image = UIImage(cgImage: cg)
        guard CGImageSourceGetCount(source) > 1 else { return LoadedPicture(image: image) }
        let ext = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredFilenameExtension } ?? "gif"
        return LoadedPicture(image: image, motion: .frames(data), file: try? saved(data, url: url, ext: ext))
    }

    /// The whole file comes down first, as the runner never sends one over
    /// 10 MB, which also means it plays from the cache with no signal. AVPlayer
    /// only plays from a URL with the right extension, so it goes in a file.
    private func decodeVideo(_ data: Data, url: URL, maxPixels: Int?) async throws -> LoadedPicture {
        guard data.count > 12, data[4..<8] == Data("ftyp".utf8) else { throw URLError(.cannotDecodeContentData) }
        let quickTime = data[8..<12] == Data("qt  ".utf8)
        let file = try saved(data, url: url, ext: quickTime ? "mov" : "mp4")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        if let maxPixels { generator.maximumSize = CGSize(width: maxPixels, height: maxPixels) }
        let poster = try await generator.image(at: .zero).image
        return LoadedPicture(image: UIImage(cgImage: poster), motion: .video, file: file)
    }

    private func saved(_ data: Data, url: URL, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Moving pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent(name).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        return file
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

    @State private var loaded: LoadedPicture?
    @State private var failed = false
    @State private var fullScreen = false

    private var size: CGSize? {
        if let size = loaded?.image.size { return size }
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
                    .disabled(loaded == nil)
                    .accessibilityLabel(alt.isEmpty ? "Picture" : alt)
                    .accessibilityHint(loaded?.isVideo == true ? "Plays it full screen" : "Shows it full screen")
            }
        }
        .task(id: url) {
            await load()
            // `-ThreadbearViewPicture <alt>`: opens that picture full screen,
            // for screenshots, as the simulator can't be tapped from a script.
            let args = CommandLine.arguments
            if loaded != nil, let i = args.firstIndex(of: "-ThreadbearViewPicture"), i + 1 < args.count, args[i + 1] == alt { fullScreen = true }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            PictureViewer(url: url, alt: alt, preview: loaded)
        }
    }

    @ViewBuilder private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        PictureFit(pixels: size, maxHeight: Self.maxHeight) {
            Group {
                if let loaded {
                    if case .frames = loaded.motion {
                        MovingPicture(picture: loaded)
                    } else {
                        Image(uiImage: loaded.image).resizable().interpolation(.high)
                            .overlay { if loaded.isVideo { PlayBadge() } }
                    }
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
            loaded = try await PictureLoader.shared.picture(url, maxPixels: Self.maxPixels)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failed = true
        }
    }
}

/// On a video's first frame in the thread, which plays once it's tapped.
private struct PlayBadge: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.title2)
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.black.opacity(0.55), in: Circle())
    }
}

/// Shows a picture and, if it has frames, plays them for as long as it's on
/// screen. ImageIO's player keeps each frame's own time and the file's loop
/// count and decodes a frame at a time, so a long GIF doesn't sit in memory
/// the way a UIImage of all its frames would. Frames it can't play (a
/// multi-picture JPEG, an unusual format) leave the first frame showing.
final class MovingImageView: UIImageView {
    /// Whether this run of the player is still wanted: its block has no other
    /// way of hearing it should stop.
    private final class Run { var stopped = false }
    private var run: Run?
    private var picture: LoadedPicture?

    func show(_ new: LoadedPicture) {
        guard new !== picture else { return }
        picture = new
        image = new.image
        play()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        play()
    }

    private func play() {
        run?.stopped = true
        run = nil
        guard window != nil, case let .frames(data) = picture?.motion else { return }
        let run = Run()
        self.run = run
        // The block comes on the main queue.
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            MainActor.assumeIsolated {
                guard let self, !run.stopped else {
                    stop.pointee = true
                    return
                }
                self.image = UIImage(cgImage: frame)
            }
        }
    }
}

private struct MovingPicture: UIViewRepresentable {
    var picture: LoadedPicture

    func makeUIView(context: Context) -> MovingImageView {
        let view = MovingImageView()
        view.contentMode = .scaleToFill
        return view
    }

    func updateUIView(_ view: MovingImageView, context: Context) {
        view.show(picture)
    }

    /// PictureFit's size, not the size of the frame in the view.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MovingImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
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

/// In place of a picture or video the phone can't have: it hasn't gone up
/// yet, it's too big, or it's from a thread too old to have been looked through.
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
/// save from the top bar. It opens clear of the notch and the top bar, so all
/// of a tall picture shows. A video plays in the system's player instead.
struct PictureViewer: View {
    var url: URL
    var alt: String
    var preview: LoadedPicture?

    @Environment(\.dismiss) private var dismiss
    @State private var full: LoadedPicture?

    /// The top bar's buttons, and a little air under them.
    private static let barHeight: CGFloat = 52

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let picture = full ?? preview {
                if picture.isVideo, let file = picture.file {
                    VideoPane(file: file)
                } else {
                    // Read here, where the safe area still counts, as the
                    // picture itself goes edge to edge once zoomed.
                    GeometryReader { screen in
                        let safe = screen.safeAreaInsets
                        ZoomableImage(picture: picture, framing: PictureFraming(top: safe.top + Self.barHeight, left: safe.leading, bottom: safe.bottom, right: safe.trailing))
                            .ignoresSafeArea()
                    }
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button { dismiss() } label: { barIcon("xmark") }
                    .accessibilityLabel("Close")
                Spacer()
                if let picture = full ?? preview {
                    shareLink(picture).accessibilityLabel("Share")
                }
            }
            .padding(.horizontal)
        }
        .statusBarHidden()
        .task {
            // A video's file is the whole of it already.
            if preview?.isVideo != true { full = try? await PictureLoader.shared.picture(url, maxPixels: nil) }
        }
    }

    /// A moving picture goes as its file, so what's shared or saved still moves.
    @ViewBuilder private func shareLink(_ picture: LoadedPicture) -> some View {
        let preview = SharePreview(alt.isEmpty ? "Picture" : alt, image: Image(uiImage: picture.image))
        if let file = picture.file {
            ShareLink(item: file, preview: preview) { barIcon("square.and.arrow.up") }
        } else {
            ShareLink(item: Image(uiImage: picture.image), preview: preview) { barIcon("square.and.arrow.up") }
        }
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: Circle())
    }
}

/// Starts playing as it opens, with sound even with the ringer off, as Mike
/// asked to see this one. Below the top bar, which would cover its controls.
private struct VideoPane: View {
    var file: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .padding(.top, 52)
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                let player = AVPlayer(url: file)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
    }
}

/// UIScrollView for the zoom, which SwiftUI's gestures only come close to:
/// pinching about the fingers, the bounce at the limits, panning a zoomed
/// picture with the same drag.
private struct ZoomableImage: UIViewRepresentable {
    var picture: LoadedPicture
    var framing: PictureFraming

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
        scroll.imageView.show(picture)
        scroll.framing = framing
        scroll.setNeedsLayout()
    }

    final class FittingScrollView: UIScrollView {
        let imageView = MovingImageView()
        var framing = PictureFraming()
        private var fittedTo: CGSize = .zero
        private var fittedPicture: CGSize?
        private var fittedFraming = PictureFraming()

        override func layoutSubviews() {
            super.layoutSubviews()
            // Fit once per size (a rotation) or picture size, never mid-zoom.
            // By its size, as a playing GIF is a new UIImage every frame, which
            // would snap a zoomed picture back.
            if fittedTo != bounds.size || fittedPicture != imageView.image?.size || fittedFraming != framing {
                fittedTo = bounds.size
                fittedPicture = imageView.image?.size
                fittedFraming = framing
                zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: framing.fitted(imageView.image?.size ?? .zero, on: bounds.size))
                contentSize = imageView.frame.size
                center()
                // From the top of the picture: insets alone leave the offset
                // at zero, with the picture up under the notch.
                contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            } else {
                center()
            }
        }

        /// Centred in the clear part of the screen while smaller than that.
        func center() {
            let insets = framing.insets(showing: contentSize, on: bounds.size)
            contentInset = UIEdgeInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
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
