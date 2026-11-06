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
    @State private var dictation = Dictation()
    @State private var askEngine = false
    private var whisperModel: WhisperModel { .shared }

    /// Each photo a chip in the words where it was put in, as on the Mac.
    private var words: PhotoWords { PhotoWords(text: $text, photos: $photos, adding: $adding, cursor: cursor) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PastableTextField(text: $text, placeholder: "What should it do?", lines: 4...12,
                                      onPasteImages: model.canSendPhotos ? { words.addPasted($0, model: model) } : nil,
                                      photos: $photos, cursor: cursor)
                    HStack {
                        if model.canSendPhotos {
                            PhotoMenu(words: words) {
                                Label("Add a photo", systemImage: "photo")
                            }
                        }
                        Spacer()
                        if dictation.isTranscribing {
                            ProgressView()
                        } else {
                            Button(action: toggleDictation) {
                                if dictation.isListening {
                                    ListeningLabel(dictation: dictation)
                                } else {
                                    Label("Dictate", systemImage: "mic")
                                }
                            }
                            .tint(dictation.isListening ? .red : nil)
                        }
                    }
                    // Two buttons in one Form row: without this a tap anywhere
                    // in the row fires both.
                    .buttonStyle(.borderless)
                    if let problem = dictation.problem {
                        Text(problem).font(.footnote).foregroundStyle(.secondary)
                    }
                    if DictationEngine.chosen == .whisper, let progress = whisperModel.progress {
                        ProgressView(value: progress) {
                            Text("Downloading Whisper. Apple's dictation until then.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if model.canSendPhotos, !photos.isEmpty || adding > 0 { PhotoStrip(words: words) }
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
                        // Nor with Whisper still to type out what was said.
                        Button("Start", action: start).disabled((words.message.isEmpty && photos.isEmpty) || adding > 0
                                                                || dictation.holdsWords)
                    }
                }
            }
            .onDisappear { dictation.close() }
            .confirmationDialog("Dictate with", isPresented: $askEngine, titleVisibility: .visible) {
                Button("Whisper, \(WhisperModel.sizeText) download") { choose(.whisper) }
                Button("Apple's dictation") { choose(.apple) }
            } message: {
                Text("Whisper's more accurate and runs on this phone. Change it in Settings.")
            }
            .task(id: "\(commandId ?? ""):\(model.connection)") { await waitForThread() }
            .task {
                if photos.isEmpty, let load = model.loadSamplePhoto { words.add([load], model: model) }
            }
        }
    }

    private var models: [PhoneModelChoice] { model.newThreadModels }
    private var chosenModel: PhoneModelChoice? { models.first { $0.id == modelId } }

    /// Adds to what's typed, after a space. The first time, asks which engine.
    private func toggleDictation() {
        if dictation.isListening { dictation.finish(); return }
        guard let engine = DictationEngine.chosen else { askEngine = true; return }
        // A download stopped by the app being swiped away picks up again.
        if engine == .whisper, !whisperModel.installed, whisperModel.progress == nil { whisperModel.download() }
        listen()
    }

    private func choose(_ engine: DictationEngine) {
        DictationEngine.chosen = engine
        if engine == .whisper { whisperModel.download() }
        listen()
    }

    private func listen() {
        let before = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "
        Task { await dictation.start { text = before + $0 } }
    }

    private func start() {
        guard let backend = model.backend else { return }
        dictation.stop()
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

/// The mic button while it's listening: the waveform, the time so far and a
/// small stop square, so it's plain the phone's hearing.
private struct ListeningLabel: View {
    let dictation: Dictation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
            HStack(spacing: 8) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(dictation.level.history.enumerated()), id: \.offset) { _, value in
                        Capsule().frame(width: 2, height: 3 + CGFloat(value) * 15)
                    }
                }
                .frame(height: 18)
                .animation(.linear(duration: 1.0 / 15), value: dictation.level.history)
                Text(elapsed(at: context.date)).monospacedDigit()
                Image(systemName: "stop.fill").imageScale(.small)
            }
        }
        .accessibilityLabel("Stop dictating")
    }

    private func elapsed(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(dictation.startedAt ?? now))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
