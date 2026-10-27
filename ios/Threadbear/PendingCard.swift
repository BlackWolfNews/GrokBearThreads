import SwiftUI
import ThreadbearKit

/// What a thread's stuck on: a permission to give, or questions to answer.
struct PendingCard: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    let pending: PendingApproval
    var onSent: (String) -> Void
    @State private var busy = false
    @State private var chosen: [Int: Set<String>] = [:]
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch pending {
            case let .approval(id, name, title, options, inputSummary):
                Label(title, systemImage: "hand.raised")
                    .font(.headline)
                if let inputSummary, !inputSummary.isEmpty {
                    Text(inputSummary)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                } else if !name.isEmpty {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(options, id: \.self) { option in
                        Button { respond(id, option) } label: {
                            Text(label(option)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(option == .allow ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
                        // Accent only on the one that moves things along.
                        .tint(option == .deny ? .red : option == .allow ? .accentColor : .secondary)
                    }
                }
                .disabled(busy)
            case let .question(id, questions):
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.question).font(.headline)
                        ForEach(question.options, id: \.label) { option in
                            optionRow(index: index, question: question, option: option)
                        }
                    }
                }
                TextField("Something else", text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    answer(id, questions)
                } label: {
                    Text("Send answer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || Answers.build(questions, chosen: chosen, typed: typed).isEmpty)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func optionRow(index: Int, question: Question, option: Question.Option) -> some View {
        let isOn = chosen[index]?.contains(option.label) == true
        return Button {
            var set = chosen[index] ?? []
            if question.multiSelect {
                if isOn { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = isOn ? [] : [option.label]
            }
            chosen[index] = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                       : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).foregroundStyle(.primary)
                    if let description = option.description {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func label(_ option: ApprovalOption) -> String {
        switch option {
        case .allow: "Allow"
        case .allowAlways: "Always"
        case .deny: "Deny"
        }
    }

    private func respond(_ approvalId: String, _ decision: ApprovalOption) {
        guard let backend = model.backend else { return }
        busy = true
        Task {
            defer { busy = false }
            do { onSent(try await backend.respond(threadId: threadId, approvalId: approvalId, decision: decision)) }
            catch { model.report(error) }
        }
    }

    private func answer(_ approvalId: String, _ questions: [Question]) {
        guard let backend = model.backend else { return }
        let answers = Answers.build(questions, chosen: chosen, typed: typed)
        busy = true
        Task {
            defer { busy = false }
            do {
                onSent(try await backend.answer(threadId: threadId, approvalId: approvalId, answers: answers,
                                                summary: Answers.summary(questions, answers: answers)))
            } catch { model.report(error) }
        }
    }
}

/// Lets one button pick bordered or prominent without two copies.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
