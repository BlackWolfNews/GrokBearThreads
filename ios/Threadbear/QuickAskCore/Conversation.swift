import Foundation

/// The last few questions and answers, sent with the next question so "and the week before?"
/// makes sense. It forgets everything after ten minutes in the background.
nonisolated struct Conversation: Equatable, Sendable {
    static let backgroundLimit: TimeInterval = 10 * 60

    private(set) var exchanges: [Exchange] = []
    private(set) var backgroundedAt: Date?

    var isEmpty: Bool { exchanges.isEmpty }

    mutating func add(question: String, answer: String) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        exchanges.append(Exchange(question: question, answer: answer))
        if exchanges.count > AskAPI.historyLimit { exchanges.removeFirst(exchanges.count - AskAPI.historyLimit) }
    }

    mutating func clear() {
        exchanges.removeAll()
    }

    mutating func didEnterBackground(at date: Date) {
        backgroundedAt = date
    }

    /// Returns true if it was old enough to forget.
    @discardableResult
    mutating func didBecomeActive(at date: Date) -> Bool {
        defer { backgroundedAt = nil }
        guard let backgroundedAt, date.timeIntervalSince(backgroundedAt) >= Self.backgroundLimit else { return false }
        let hadAny = !exchanges.isEmpty
        exchanges.removeAll()
        return hadAny
    }
}
