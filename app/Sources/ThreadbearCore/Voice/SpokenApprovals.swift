import Foundation

/// Which approval card a spoken yes or no answers in Voice mode.
///
/// A spoken answer only ever goes to the card whose question was read out
/// to the end, while that card is still open, unchanged and the newest
/// one waiting. Before this (7 Nov review), "yes" answered whichever card
/// was pending when he spoke, so a card that came in just before he
/// answered the last one got his yes without him ever hearing it, and a
/// voice yes can let a tool run. So a new card, or a changed one, unbinds
/// the answer until it has been read out in turn, and an answer said
/// meanwhile isn't sent anywhere: the newest card is read out again.
public struct SpokenApprovals: Sendable, Equatable {
    /// Cards waiting, oldest first.
    public private(set) var open: [ApprovalRequest] = []
    /// The card read out to the end, which an answer may go to.
    public private(set) var heard: ApprovalRequest?

    public init() {}

    public enum Outcome: Equatable, Sendable {
        /// Answer this card with this decision.
        case answer(ApprovalRequest, ApprovalDecision)
        /// It sounded like an answer, but not to a card he has heard: read
        /// this one (the newest) out again rather than guess.
        case readAgain(ApprovalRequest)
        /// It sounded like an answer, but the newest card is one Voice
        /// doesn't answer (`answerable`): it's for the screen.
        case onScreen(ApprovalRequest)
        /// Not an answer, or no card waiting: his words go as a message.
        case message
    }

    /// Voice reads this card out and may answer it. Another Mac asking for
    /// a thread (StartRequest) and a plan waiting to go ahead are left to
    /// the screen: what they'd set going is shown there and isn't read out.
    public static func answerable(_ card: ApprovalRequest) -> Bool {
        card.name != StartRequest.cardName && card.name != "ExitPlanMode"
    }

    /// A card came in (or came again, maybe changed). Nothing heard counts
    /// until this one, the newest, has been read out.
    public mutating func requested(_ card: ApprovalRequest) {
        open.removeAll { $0.approvalId == card.approvalId }
        open.append(card)
        heard = nil
    }

    /// The card was settled, on screen, by voice or by the runner.
    public mutating func resolved(_ approvalId: String) {
        open.removeAll { $0.approvalId == approvalId }
        if heard?.approvalId == approvalId { heard = nil }
    }

    /// The card's question finished playing. It's what an answer goes to
    /// only if it's still the newest card open, exactly as it was read.
    public mutating func readOut(_ card: ApprovalRequest) {
        guard Self.answerable(card), open.last == card else { return }
        heard = card
    }

    public mutating func clear() {
        open = []
        heard = nil
    }

    /// What `said` does: answers the heard card, asks for the newest to
    /// be read again, or is a message.
    public mutating func take(_ said: String) -> Outcome {
        guard let newest = open.last else { return .message }
        if let card = heard, card == newest, let decision = SpokenAnswer.decision(said, options: card.options) {
            open.removeLast()
            heard = nil
            return .answer(card, decision)
        }
        // Any answer at all, to any card: not sent as a message ("yes" in
        // the thread would decline the card), and not guessed at.
        guard SpokenAnswer.decision(said, options: [.allow, .allowAlways, .deny]) != nil else { return .message }
        return Self.answerable(newest) ? .readAgain(newest) : .onScreen(newest)
    }
}
