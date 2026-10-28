import AppKit
import ThreadbearCore

/// Explain (docs/protocol.md, "Explain"): words Mike selects in the
/// transcript, explained by the small model in the pane beside it, with
/// follow-ups. Nothing goes into the thread. Also the selection bar's other
/// actions, quoting into the composer.
extension AppModel {
    /// The selection bar's Explain: a fresh side conversation for this
    /// thread, shown in the pane, replacing any earlier one.
    func explain(_ selection: String, message: String?, in threadId: String) {
        guard let thread = threads[threadId], !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        explainCount += 1
        let session = ExplainSession(id: explainCount, selection: selection, message: message)
        explainers[threadId] = session
        show(PanePreview(target: .explain, title: "Explain", from: paneSection(for: thread)), in: threadId)
        fetchExplanation(threadId, turn: 0)
    }

    func askExplainer(_ question: String, in threadId: String) {
        guard let index = explainers[threadId]?.ask(question) else { return }
        fetchExplanation(threadId, turn: index)
    }

    func retryExplainer(turn index: Int, in threadId: String) {
        guard explainers[threadId]?.retry(index) == true else { return }
        fetchExplanation(threadId, turn: index)
    }

    private func fetchExplanation(_ threadId: String, turn index: Int) {
        guard let session = explainers[threadId] else { return }
        Task {
            let outcome: Result<ExplainResult, Error>
            if let client {
                do { outcome = .success(try await client.explain(session, threadId: threadId, turn: index)) } catch { outcome = .failure(error) }
            } else {
                outcome = .failure(RPCError.disconnected(nil))
            }
            // Mike may have explained something else meanwhile.
            guard explainers[threadId]?.id == session.id, explainers[threadId]?.turns.indices.contains(index) == true else { return }
            switch outcome {
            case .success(let result):
                explainers[threadId]?.turns[index].answer = result.answer
            case .failure(RPCError.server(let code, _)) where code == RPCError.methodNotFound:
                explainers[threadId]?.turns[index].error = "The runner doesn't know Explain yet. It will once it updates."
            case .failure(let error):
                explainers[threadId]?.turns[index].error = error.localizedDescription
            }
        }
    }

    /// The selection bar's Quote: the words as a Markdown quote at the end
    /// of the thread's draft, ready for Mike to say what about them.
    func quoteInComposer(_ selection: String, in threadId: String) {
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
        guard !quote.isEmpty else { return }
        var draft = drafts[threadId] ?? Draft()
        let before = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft.text.trimmingCharacters(in: .newlines) + "\n\n"
        draft.text = before + quote + "\n\n"
        drafts[threadId] = draft
        focusComposer += 1
    }
}
