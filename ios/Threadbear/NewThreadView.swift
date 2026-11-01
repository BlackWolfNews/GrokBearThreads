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
    /// From the tap on Start until the command's queued. A separate job from
    /// waiting on the runner, and without it Start looks dead (and can be
    /// tapped again, for a second thread) while the photos finish going up.
    @State private var starting: Task<Void, Never>?
    @State private var photos: [PickedPhoto] = []
    @State private var adding = 0
    @State private var cursor = TextCursor()

    /// Each photo a chip in the words where it was put in, as on the Mac.
    private var words: PhotoWords { PhotoWords(text: $text, photos: $photos, adding: $adding, cursor: cursor) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PastableTextField(text: $text, placeholder: "What should it do?", lines: 4...12,
                                      onPasteImages: model.canSendPhotos ? { words.addPasted($0, model: model) } : nil,
                                      photos: $photos, cursor: cursor)
                    if model.canSendPhotos {
                        PhotoMenu(words: words) {
                            Label("Add a photo", systemImage: "photo")
                        }
                        if !photos.isEmpty || adding > 0 { PhotoStrip(words: words) }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        starting?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if commandId != nil || starting != nil { ProgressView() } else {
                        // Not with a photo still on its way, which would be left behind.
                        Button("Start", action: start).disabled((words.message.isEmpty && photos.isEmpty) || adding > 0)
                    }
                }
            }
            .task(id: "\(commandId ?? ""):\(model.connection)") { await waitForThread() }
            .task {
                if photos.isEmpty, let load = model.loadSamplePhoto { words.add([load], model: model) }
            }
        }
    }

    private var models: [PhoneModelChoice] { model.newThreadModels }
    private var chosenModel: PhoneModelChoice? { models.first { $0.id == modelId } }

    private func start() {
        guard let backend = model.backend else { return }
        let message = words.message
        let photos = photos
        starting = Task {
            defer { starting = nil }
            do {
                let images = try await model.upload(photos)
                // Cancelled while the photos were going up: no thread after all.
                try Task.checkCancellation()
                commandId = try await backend.create(text: message, runnerId: nil, cwd: nil, images: images,
                                                     settings: NewThreadSettings(model: modelId, effort: effort))
                model.sent(photos)
            } catch is CancellationError {
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
                    onCreated(threadId)
                    dismiss()
                    return
                }
                if status?.state == .failed {
                    model.report(TransportError.server(status?.note ?? "The runner couldn't start it."))
                    // The backend deleted the copies with the failed command,
                    // so trying again needs new ones.
                    for photo in photos { photo.upload = nil }
                    self.commandId = nil
                    return
                }
            }
        } catch {
            model.report(error)
        }
    }
}
