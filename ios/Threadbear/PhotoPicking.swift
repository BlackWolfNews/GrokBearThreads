import PhotosUI
import SwiftUI
import ThreadbearKit

/// A photo waiting in a composer. Once uploaded it keeps its storage id, so
/// trying a failed send again doesn't leave a second copy in Convex.
@MainActor final class PickedPhoto: Identifiable {
    nonisolated let id = UUID()
    let jpeg: Data
    let thumbnail: UIImage
    var storageId: String?
    /// Small enough to draw into its chip each time the words are laid out
    /// (PhotoChips.swift), its short side 96 px.
    lazy var chipThumbnail: UIImage = {
        let side = min(thumbnail.size.width, thumbnail.size.height)
        guard side > 96 else { return thumbnail }
        let scale = 96 / side
        return thumbnail.preparingThumbnail(of: CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)) ?? thumbnail
    }()

    init?(jpeg: Data) {
        guard let thumbnail = UIImage(data: jpeg) else { return nil }
        self.jpeg = jpeg
        self.thumbnail = thumbnail
    }

    /// Ready to send, or nil if it can't be read as an image.
    static func from(_ data: Data) async -> PickedPhoto? {
        let jpeg = await Task.detached(priority: .userInitiated) { PhotoPrep.jpeg(from: data) }.value
        return jpeg.flatMap { PickedPhoto(jpeg: $0) }
    }
}

/// Photos pasted into a composer, made ready to send and then put in
/// (`PhotoWords.insert`, which takes as many as still fit).
@MainActor func addPasted(_ images: [Data], model: AppModel, insert: @escaping ([PickedPhoto]) -> Void) {
    Task {
        var picked: [PickedPhoto] = []
        for data in images.prefix(PhotoPrep.maxPhotos) {
            if let photo = await PickedPhoto.from(data) {
                picked.append(photo)
            } else {
                model.report(TransportError.server("Couldn't read that photo."))
            }
        }
        if !picked.isEmpty { insert(picked) }
    }
}

/// Where a composer's cursor is, in its words (UTF-16). A plain reference,
/// so moving the cursor doesn't redraw the composer; the text field keeps
/// it up to date and puts the cursor back there after the words change.
final class TextCursor {
    var range = NSRange(location: NSNotFound, length: 0)
}

/// A composer's words and photos together: each photo a chip in the words,
/// a mark there (InlinePictures), and the photos in the marks' order.
@MainActor struct PhotoWords {
    var text: Binding<String>
    var photos: Binding<[PickedPhoto]>
    var cursor: TextCursor

    /// New photos as chips where the cursor is (the end, before it's been
    /// in the box), as many as still fit.
    func insert(_ new: [PickedPhoto]) {
        let have = photos.wrappedValue
        let new = Array(new.prefix(max(0, PhotoPrep.maxPhotos - have.count)))
        guard !new.isEmpty else { return }
        let words = InlinePictures.normalized(text.wrappedValue, count: have.count)
        let at = cursor.range.location == NSNotFound ? NSRange(location: (words as NSString).length, length: 0) : cursor.range
        let result = InlinePictures.inserting(new.count, in: words, replacing: at)
        var all = have
        all.insert(contentsOf: new, at: min(result.firstIndex, all.count))
        cursor.range = NSRange(location: result.cursor, length: 0)
        photos.wrappedValue = all
        text.wrappedValue = result.text
    }

    /// The strip's remove button: the photo and its chip.
    func remove(_ photo: PickedPhoto) {
        var all = photos.wrappedValue
        guard let index = all.firstIndex(where: { $0.id == photo.id }) else { return }
        let words = InlinePictures.normalized(text.wrappedValue, count: all.count)
        all.remove(at: index)
        photos.wrappedValue = all
        text.wrappedValue = InlinePictures.removingMark(index, from: words)
    }

    /// What's sent: the words with each chip as a [Picture N] marker, or
    /// none when there are only photos.
    var message: String {
        InlinePictures.sentText(InlinePictures.normalized(text.wrappedValue, count: photos.wrappedValue.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The menu that adds a photo: take one or choose from the library. The
/// library picker runs outside the app, so it needs no permission; the camera
/// asks the first time. Left out where there's no camera (the simulator).
struct PhotoMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var photos: [PickedPhoto]
    /// Puts each one in as a chip where the cursor is (PhotoWords.insert);
    /// without it, they go on the end of `photos`.
    var onAdd: (([PickedPhoto]) -> Void)? = nil
    @ViewBuilder var label: () -> Label
    @State private var choosing = false
    @State private var chosen: [PhotosPickerItem] = []
    @State private var takingPhoto = false

    var body: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { takingPhoto = true }
            }
            Button("Choose Photo", systemImage: "photo.on.rectangle") { choosing = true }
        } label: {
            label()
        }
        .disabled(photos.count >= PhotoPrep.maxPhotos)
        .photosPicker(isPresented: $choosing, selection: $chosen, maxSelectionCount: max(1, PhotoPrep.maxPhotos - photos.count), matching: .images)
        .onChange(of: chosen) {
            let items = chosen
            guard !items.isEmpty else { return }
            chosen = []
            Task {
                for item in items {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await add(data)
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in Task { await add(data) } }
                .ignoresSafeArea()
        }
    }

    private func add(_ data: Data?) async {
        guard photos.count < PhotoPrep.maxPhotos else { return }
        if let data, let photo = await PickedPhoto.from(data) {
            if let onAdd { onAdd([photo]) } else { photos.append(photo) }
        } else {
            model.report(TransportError.server("Couldn't read that photo."))
        }
    }
}

/// The photos waiting to go, each with a button to take it out.
struct PhotoStrip: View {
    @Binding var photos: [PickedPhoto]
    /// Takes its chip out of the words too (PhotoWords.remove).
    var onRemove: ((PickedPhoto) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                if let onRemove { onRemove(photo) } else { photos.removeAll { $0.id == photo.id } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 20))
                                    .padding(3)
                            }
                            .accessibilityLabel("Remove photo")
                        }
                        .accessibilityLabel("Photo to send")
                }
            }
        }
    }
}

/// The system camera. There's no SwiftUI one, so UIKit's picker, as QRScanner
/// wraps UIKit for the pairing code.
private struct CameraPicker: UIViewControllerRepresentable {
    var onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 1) { parent.onPhoto(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
