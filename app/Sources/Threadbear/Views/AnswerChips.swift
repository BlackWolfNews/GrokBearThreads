import SwiftUI
import ThreadbearCore

/// The answers Mike picked on the open card of asks (in the transcript,
/// under the agent's message), waiting over the composer to go with his
/// next message: the ask's number and the answer, × to unpick it. The
/// composer stays the only place to write, so his own words and images go
/// with them (docs/protocol.md, "Needs you", Answering).
struct AnswerChips: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let picks: [Int: Int]

    var body: some View {
        // "Something else" shows as a chip too, before he's written it.
        let answers = Decisions.answers(asks: thread.asks, picks: picks, written: "…").map { index, answer in
            (index: index, answer: picks[index] == Decisions.ownAnswer ? AskAnswer(action: answer.action, answer: "Your answer below") : answer)
        }
        // In a row that scrolls, like the action chips.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: zoomed(6)) {
                ForEach(answers, id: \.index) { index, answer in
                    chip(index: index, answer: answer)
                }
            }
        }
    }

    private func chip(index: Int, answer: AskAnswer) -> some View {
        HStack(spacing: zoomed(6)) {
            if thread.asks.count > 1 {
                Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
            }
            if picks[index] == Decisions.ownAnswer {
                Image(systemName: "pencil").font(.system(size: zoomed(10), weight: .medium)).foregroundStyle(.secondary)
            }
            Text(answer.answer).foregroundStyle(.primary).lineLimit(1)
            Button {
                if let option = picks[index] { app.pickAnswer(thread: thread, ask: index, option: option) }
            } label: {
                Image(systemName: "xmark").font(.system(size: zoomed(9), weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .tip("Take this answer back")
        }
        .font(.system(size: TypeScale.chip))
        .padding(.horizontal, zoomed(9))
        .padding(.vertical, zoomed(4))
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5))
        .tip(answer.action)
    }
}
