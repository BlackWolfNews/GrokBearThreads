import SwiftUI
import ThreadbearKit

/// A new thread from the phone. Like the Mac it starts in misc on the
/// last-used account unless you pick a folder; the runner fills the rest.
struct NewThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void
    @State private var text: String

    init(text: String = "", onCreated: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.onCreated = onCreated
    }
    @State private var folder: String?
    @State private var commandId: String?
    @State private var photos: [PickedPhoto] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it do?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                    if model.canSendPhotos {
                        PhotoMenu(photos: $photos) {
                            Label("Add a photo", systemImage: "photo")
                        }
                        if !photos.isEmpty { PhotoStrip(photos: $photos) }
                    }
                }
                Section("Folder") {
                    Picker("Folder", selection: $folder) {
                        Text("misc (the usual)").tag(String?.none)
                        ForEach(recentFolders, id: \.self) { Text(Self.short($0)).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
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
                        Button("Start", action: start).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty)
                    }
                }
            }
            .task(id: commandId) { await waitForThread() }
            .task {
                if photos.isEmpty, let sample = model.samplePhoto, let photo = await PickedPhoto.from(sample) { photos = [photo] }
            }
        }
    }

    /// Folders of recent threads, most used first, misc left out (it's the default).
    private var recentFolders: [String] {
        var counts: [String: Int] = [:]
        for thread in model.inbox + model.hibernating + model.den.prefix(30) { counts[thread.cwd, default: 0] += 1 }
        return counts.filter { !$0.key.hasSuffix("/misc") }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8).map(\.key)
    }

    static func short(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }

    private func start() {
        guard let backend = model.backend else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let images = try await model.upload(photos)
                commandId = try await backend.create(text: message, runnerId: nil, cwd: folder, images: images)
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
