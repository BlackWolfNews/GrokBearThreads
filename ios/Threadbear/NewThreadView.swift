import SwiftUI
import ThreadbearKit

/// A new thread from the phone. It starts in the runner's default folder
/// (Mike didn't want a folder picker on the phone, 31 Oct); the model and
/// effort can be picked, and the runner picks a login with room for them.
struct NewThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void
    @State private var text: String

    init(text: String = "", onCreated: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.onCreated = onCreated
    }
    @State private var modelId: String?
    @State private var effort: String?
    @State private var commandId: String?
    @State private var photos: [PickedPhoto] = []
    @State private var cursor = TextCursor()

    /// Each photo a chip in the words where it was put in, as on the Mac.
    private var words: PhotoWords { PhotoWords(text: $text, photos: $photos, cursor: cursor) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PastableTextField(text: $text, placeholder: "What should it do?", lines: 4...12,
                                      onPasteImages: model.canSendPhotos ? { addPasted($0, model: model) { words.insert($0) } } : nil,
                                      photos: $photos, cursor: cursor)
                    if model.canSendPhotos {
                        PhotoMenu(photos: $photos, onAdd: { words.insert($0) }) {
                            Label("Add a photo", systemImage: "photo")
                        }
                        if !photos.isEmpty { PhotoStrip(photos: $photos) { words.remove($0) } }
                    }
                }
                if !models.isEmpty {
                    Section {
                        Picker("Model", selection: $modelId) {
                            Text("Default").tag(String?.none)
                            ForEach(models) { Text($0.title).tag(Optional($0.id)) }
                        }
                        Picker("Effort", selection: $effort) {
                            Text("Default").tag(String?.none)
                            ForEach(NewThreadChoices.efforts(for: chosenModel), id: \.self) { Text(NewThreadChoices.effortTitle($0)).tag(Optional($0)) }
                        }
                    }
                    .onChange(of: modelId) {
                        // Codex's Ultra on a Claude model, say: back to the model's own.
                        if !NewThreadChoices.keeps(effort: effort, model: chosenModel) { effort = nil }
                    }
                }
                if let offline = model.offlineText {
                    Section { Label("\(offline). It'll start when it's back.", systemImage: "moon.zzz").font(.footnote) }
                }
            }
            .navigationTitle("New thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if commandId != nil { ProgressView() } else {
                        Button("Start", action: start).disabled(words.message.isEmpty && photos.isEmpty)
                    }
                }
            }
            .task(id: "\(commandId ?? ""):\(model.connection)") { await waitForThread() }
            .task {
                if photos.isEmpty, let sample = model.samplePhoto, let photo = await PickedPhoto.from(sample) { words.insert([photo]) }
            }
        }
    }

    private var models: [PhoneModelChoice] { model.newThreadModels }
    private var chosenModel: PhoneModelChoice? { models.first { $0.id == modelId } }

    private func start() {
        guard let backend = model.backend else { return }
        let message = words.message
        Task {
            do {
                let images = try await model.upload(photos)
                commandId = try await backend.create(text: message, runnerId: nil, cwd: nil, images: images,
                                                     settings: NewThreadSettings(model: modelId, effort: effort))
            } catch {
                model.report(error)
            }
        }
    }

    /// The thread id arrives once the runner's made it. With the Mac asleep
    /// that's later, so the sheet closes and the thread turns up in the
    /// inbox when it starts.
    private func waitForThread() async {
        guard let commandId, let backend = model.backend else { return }
        if model.offlineText != nil { dismiss(); return }
        do {
            for try await status in backend.command(commandId) {
                if let threadId = status?.threadId {
                    dismiss()
                    onCreated(threadId)
                    return
                }
                if status?.state == .failed {
                    model.report(TransportError.server(status?.note ?? "The runner couldn't start it."))
                    self.commandId = nil
                    return
                }
            }
        } catch {
            model.report(error)
        }
    }
}
