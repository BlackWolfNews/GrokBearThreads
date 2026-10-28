import SwiftUI
import ThreadbearCore

/// Where Mike is on a thread's open card of asks (docs/protocol.md, "Needs
/// you", Answering): which one he's on (`asks.count` is the summary), what
/// he's said so far, and whether he put it away for the plain composer.
/// Kept per thread in AppModel; a new card starts it again.
struct DecisionProgress: Equatable {
    var asksSeq: Int
    var step = 0
    var answers: [Int: DecisionAnswer] = [:]
    var dismissed = false
}

/// The open card's asks one at a time, in the composer's place: each
/// one's choices, a box for his own words, Later, and at the end every
/// answer with room for anything else, sent as one message. The survey
/// behind it (27 Oct 2026): most answers were a pick or a short yes, but a
/// lot weren't, so the box is always there.
struct DecisionPager: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    @Binding var progress: DecisionProgress
    @Binding var extra: String
    @FocusState private var typing: Bool

    private var asks: [Ask] { thread.asks }
    private var onSummary: Bool { progress.step >= asks.count }

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(10)) {
            HStack {
                Text(onSummary ? "Your answers" : "\(progress.step + 1) of \(asks.count)")
                    .font(.system(size: TypeScale.detail))
                    .foregroundStyle(.secondary)
                Spacer()
                StepDots(count: asks.count, step: progress.step, answered: { progress.answers[$0]?.isAnswered == true }) { progress.step = $0 }
            }
            if onSummary { summary } else { step(progress.step) }
            footer
        }
        // Esc puts the card away for the plain composer; the chip there
        // brings it back with the answers kept.
        .onExitCommand { progress.dismissed = true }
        .onKeyPress(phases: .down) { press in
            guard !typing, !onSummary else { return .ignored }
            if press.key == .return { next(); return .handled }
            if let digit = Int(press.characters), digit >= 1, digit <= Decisions.choices(for: asks[progress.step]).count {
                pick(digit - 1)
                return .handled
            }
            return .ignored
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear { if onSummary { typing = true } }
    }

    // MARK: - One ask

    @ViewBuilder private func step(_ i: Int) -> some View {
        let ask = asks[i]
        let current = Decisions.answer(i, asks: asks, answers: progress.answers)
        VStack(alignment: .leading, spacing: zoomed(4)) {
            Text(ask.action)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let why = ask.why {
                Text(why).font(.system(size: TypeScale.label)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let place = ask.where_ {
                Text(place).font(.system(size: TypeScale.detail)).foregroundStyle(.tertiary)
            }
        }
        VStack(alignment: .leading, spacing: zoomed(3)) {
            ForEach(Array(Decisions.choices(for: ask).enumerated()), id: \.offset) { n, choice in
                ChoiceRow(
                    number: n + 1, text: choice,
                    suggested: ask.suggested == n,
                    selected: current?.choice == n && current?.later != true
                ) { pick(n) }
            }
            OtherField(
                text: Binding(
                    get: { progress.answers[i]?.text ?? "" },
                    set: { text in
                        // Typing keeps a pick he made (a note on it), but on
                        // its own it replaces the agent's suggestion.
                        var answer = progress.answers[i] ?? DecisionAnswer()
                        answer.text = text
                        answer.later = false
                        progress.answers[i] = answer
                    }
                ),
                placeholder: progress.answers[i]?.choice != nil ? "Add a note…" : "Other…",
                number: Decisions.choices(for: ask).count + 1,
                onSubmit: next
            )
            .focused($typing)
        }
    }

    private var footer: some View {
        HStack(spacing: zoomed(8)) {
            if progress.step > 0 {
                Button("Back") { progress.step -= 1 }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .tip("Go back to the last decision")
            } else {
                Text("Esc for a normal message").foregroundStyle(.tertiary)
            }
            Spacer()
            if onSummary {
                Button("Send") { app.sendDecisions(thread: thread) }
                    .buttonStyle(.borderedProminent)
                    .disabled(Decisions.message(asks: asks, answers: progress.answers, extra: extra).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .tip("Send your answers as one message (⌘↩)")
            } else {
                Button("Later") {
                    progress.answers[progress.step] = DecisionAnswer(later: true)
                    progress.step += 1
                }
                .tip("Leave this one open and go to the next")
                Button(progress.step == asks.count - 1 ? "Review" : "Next") { next() }
                    .buttonStyle(.borderedProminent)
                    .tip("Go to the next decision (↩)")
            }
        }
        .font(.system(size: TypeScale.detail))
        .controlSize(.small)
    }

    // MARK: - The summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: zoomed(8)) {
            ForEach(Array(asks.enumerated()), id: \.offset) { i, ask in
                let text = Decisions.answerText(Decisions.answer(i, asks: asks, answers: progress.answers), ask: ask)
                Button { progress.step = i } label: {
                    HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
                        Text("\(i + 1). \(ask.action)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(text ?? "No answer")
                            .foregroundStyle(text == nil ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: TypeScale.label))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip("Change this answer")
            }
            OtherField(text: $extra, placeholder: "Anything else?", number: nil, onSubmit: { app.sendDecisions(thread: thread) })
                .focused($typing)
        }
    }

    // MARK: - Moving on

    /// A pick moves straight on: most answers are a single pick, and Back
    /// is there for adding a note.
    private func pick(_ n: Int) {
        var answer = progress.answers[progress.step] ?? DecisionAnswer()
        answer.choice = n
        answer.later = false
        progress.answers[progress.step] = answer
        progress.step += 1
    }

    private func next() {
        progress.step = min(progress.step + 1, asks.count)
        typing = progress.step >= asks.count
    }
}

private struct ChoiceRow: View {
    let number: Int
    let text: String
    let suggested: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: zoomed(8), style: .continuous)
        Button(action: action) {
            HStack(spacing: zoomed(10)) {
                KeyCap(number: number)
                Text(text).foregroundStyle(.primary)
                if suggested {
                    Text("suggested").font(.system(size: TypeScale.small)).foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: TypeScale.label))
            .padding(.horizontal, zoomed(10))
            .padding(.vertical, zoomed(7))
            .background(shape.fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
            .overlay(shape.strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .tip(suggested ? "The agent's pick. Press \(number) or click to choose it" : "Press \(number) or click to choose this")
    }
}

/// The box for his own words: an Other answer, a note on a pick, or the
/// summary's anything else. Grows as he types; Return moves on and
/// Shift-Return adds a line.
private struct OtherField: View {
    @Binding var text: String
    let placeholder: String
    let number: Int?
    let onSubmit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: zoomed(8), style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
            if let number { KeyCap(number: number) }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    onSubmit()
                    return .handled
                }
                .tip("Write your own answer")
        }
        .font(.system(size: TypeScale.label))
        .padding(.horizontal, zoomed(10))
        .padding(.vertical, zoomed(7))
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
    }
}

private struct KeyCap: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: TypeScale.small, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: zoomed(18))
            .overlay(RoundedRectangle(cornerRadius: zoomed(4)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
    }
}

/// One dash per ask: filled for the one he's on, softer for answered ones.
/// Clicking one goes to it.
private struct StepDots: View {
    let count: Int
    let step: Int
    let answered: (Int) -> Bool
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: zoomed(5)) {
            ForEach(0..<count, id: \.self) { i in
                Button { go(i) } label: {
                    Capsule()
                        .fill(i == step ? Color.accentColor : answered(i) ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12))
                        .frame(width: zoomed(18), height: zoomed(4))
                        .padding(.vertical, zoomed(4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip("Go to decision \(i + 1)")
            }
        }
    }
}

/// Over the plain composer once the card is put away: a way back to it.
struct DecisionsChip: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: zoomed(5)) {
                Image(systemName: "list.number").font(.system(size: zoomed(11), weight: .medium)).foregroundStyle(.secondary)
                Text(count == 1 ? "Answer the decision" : "Answer the \(count) decisions").foregroundStyle(.primary)
            }
            .font(.system(size: TypeScale.chip))
            .padding(.horizontal, zoomed(9))
            .padding(.vertical, zoomed(4))
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip("Step through what the agent needs from you")
    }
}
