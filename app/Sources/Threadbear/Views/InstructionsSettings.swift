import SwiftUI
import ThreadbearCore

/// Instructions: what every thread's agent should always keep in mind
/// (who he is, how to write, what he works with), given to every session
/// on every login, Claude and Codex (docs/protocol.md).
/// Folded away until he opens it; empty is fine. Saved a moment after he
/// stops typing, and when it's folded or the page closes.
struct InstructionsBox: View {
    @Environment(AppModel.self) private var app
    @State private var open = false
    @State private var text = ""
    @State private var loaded = false
    @State private var status: String?
    @State private var save: Task<Void, Never>?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(8)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
                if open {
                    // Ready to type straight away.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { typing = true }
                } else {
                    commit()
                }
            } label: {
                HStack(spacing: zoomed(6)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: zoomed(10), weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Instructions").font(.headline)
                    if !open {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(open ? "Fold the instructions away" : "What every thread's agent should always keep in mind")
            if open {
                Text("Threadbear gives these to every thread's agent in every session, on every login, Claude and Codex alike. A chat that's already going hears a change before your next message. Leave it empty for none.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(zoomed(6))
                    .frame(minHeight: zoomed(120), maxHeight: zoomed(300))
                    .background(RoundedRectangle(cornerRadius: zoomed(8)).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(Color.accentColor.opacity(0.35)))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("For example: You're a senior full-stack developer and marketer. Write plainly and briefly. I build with React, TypeScript and Convex.")
                                .foregroundStyle(.tertiary)
                                .padding(zoomed(11))
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($typing)
                    .onChange(of: text) { _, _ in scheduleSave() }
                    .tip("Your standing instructions for every agent")
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if !loaded { text = app.standingInstructions; loaded = true }
        }
        .onChange(of: app.standingInstructions) { _, new in
            // Set elsewhere (or loaded late) while he isn't typing here.
            if save == nil, new.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) { text = new }
        }
        .onDisappear { commit() }
    }

    private var summary: String {
        let first = app.standingInstructions.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map(String.init) ?? "None set"
    }

    private func scheduleSave() {
        guard loaded else { return }
        save?.cancel()
        status = nil
        save = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    private func commit() {
        guard loaded, save != nil else { return }
        save?.cancel()
        Task { await write() }
    }

    private func write() async {
        save = nil
        let wanted = text
        guard wanted.trimmingCharacters(in: .whitespacesAndNewlines) != app.standingInstructions.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if let error = await app.saveStandingInstructions(wanted) { status = error } else { status = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Cleared" : "Saved" }
    }
}
