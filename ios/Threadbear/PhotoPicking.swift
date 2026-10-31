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

/// The menu that adds a photo: take one or choose from the library. The
/// library picker runs outside the app, so it needs no permission; the camera
/// asks the first time. Left out where there's no camera (the simulator).
struct PhotoMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var photos: [PickedPhoto]
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
            photos.append(photo)
        } else {
            model.report(TransportError.server("Couldn't read that photo."))
        }
    }
}

/// The photos waiting to go, each with a button to take it out.
struct PhotoStrip: View {
    @Binding var photos: [PickedPhoto]

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
                                photos.removeAll { $0.id == photo.id }
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
