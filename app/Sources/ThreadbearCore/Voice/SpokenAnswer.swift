import Foundation

/// A yes or a no said to an approval card in Voice mode. Only an answer on
/// its own counts ("yes", "yeah go ahead", "no thanks"): every word has to
/// be one of an answer's words, so anything more ("no, use the other
/// folder") is a message, which declines the card with his words, as
/// typing does.
public enum SpokenAnswer {
    public static func decision(_ said: String, options: [ApprovalOption]) -> ApprovalDecision? {
        let words = said.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
            .filter { !filler.contains($0) }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let set = Set(words)
        if !set.isDisjoint(with: noCore) {
            return options.contains(.deny) && set.isSubset(of: noWords) ? .deny : nil
        }
        guard !set.isDisjoint(with: yesCore), set.isSubset(of: yesWords.union(["always"])) else { return nil }
        if set.contains("always") { return options.contains(.allowAlways) ? .allowAlways : nil }
        return options.contains(.allow) ? .allow : nil
    }

    /// Said round an answer and meaning nothing on their own.
    static let filler: Set<String> = ["um", "uh", "er", "erm", "hmm", "please", "thanks", "thank", "you", "bear", "threadbear", "and", "then"]

    /// Words that make it a yes, and every word a yes can have.
    static let yesCore: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "allow", "approve", "approved", "go", "do", "fine", "good", "run", "always"]
    static let yesWords: Set<String> = yesCore.union(["ahead", "for", "it", "that", "that's", "sounds", "great", "perfect", "is", "on"])

    /// Words that make it a no, and every word a no can have.
    static let noCore: Set<String> = ["no", "nope", "nah", "deny", "don't", "dont", "stop", "cancel", "decline", "skip", "not"]
    static let noWords: Set<String> = noCore.union(["do", "it", "that", "way", "now", "yet", "this"])
}
