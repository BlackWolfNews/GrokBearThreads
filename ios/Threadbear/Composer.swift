import SwiftUI

/// The text box at the bottom of a thread: type, or use the keyboard's own
/// dictation, add photos, then send.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    var placeholder: String
    /// Returns whether it went, so a failed send keeps the text.
    var onSend: (String, [PickedPhoto]) async -> Bool
    @State private var photos: [PickedPhoto] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !photos.isEmpty {
                PhotoStrip(photos: $photos)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if model.canSendPhotos {
                    PhotoMenu(photos: $photos) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    // A menu's label takes the accent otherwise, and only Send should have it.
                    .tint(.secondary)
                    .accessibilityLabel("Add a photo")
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button(action: send) {
                    // A photo can take a while to go up on mobile data.
                    if sending && !photos.isEmpty {
                        ProgressView().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                }
                .disabled((trimmed.isEmpty && photos.isEmpty) || sending)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .task {
            if photos.isEmpty, let sample = model.samplePhoto, let photo = await PickedPhoto.from(sample) { photos = [photo] }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let message = trimmed
        guard !message.isEmpty || !photos.isEmpty else { return }
        sending = true
        Task {
            if await onSend(message, photos) {
                text = ""
                photos = []
            }
            sending = false
        }
    }
}
