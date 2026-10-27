import SwiftUI

/// The text box at the bottom of a thread: type or tap the mic, then send.
struct Composer: View {
    @Binding var text: String
    var placeholder: String
    /// Returns whether it went, so a failed send keeps the text.
    var onSend: (String) async -> Bool
    @State private var dictation = Dictation()
    @State private var sending = false
    /// What was typed before the mic started, so dictation adds to it.
    @State private var before = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let problem = dictation.problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(dictation.isListening ? "Listening…" : placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button(action: toggleMic) {
                    Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(dictation.isListening ? Color.red : .secondary)
                }
                .accessibilityLabel(dictation.isListening ? "Stop listening" : "Dictate")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(trimmed.isEmpty || sending)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onDisappear { dictation.stop() }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func toggleMic() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        before = trimmed.isEmpty ? "" : trimmed + " "
        Task {
            await dictation.start { spoken in text = before + spoken }
        }
    }

    private func send() {
        let message = trimmed
        guard !message.isEmpty else { return }
        dictation.stop()
        sending = true
        Task {
            if await onSend(message) { text = "" }
            sending = false
        }
    }
}
