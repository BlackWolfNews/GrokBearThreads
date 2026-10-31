import SwiftUI

/// The text box at the bottom of a thread: type, or use the keyboard's own
/// dictation, then send.
struct Composer: View {
    @Binding var text: String
    var placeholder: String
    /// Returns whether it went, so a failed send keeps the text.
    var onSend: (String) async -> Bool
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(trimmed.isEmpty || sending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let message = trimmed
        guard !message.isEmpty else { return }
        sending = true
        Task {
            if await onSend(message) { text = "" }
            sending = false
        }
    }
}
