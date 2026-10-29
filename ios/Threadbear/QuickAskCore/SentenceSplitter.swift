import Foundation

/// Cuts the streamed answer into sentences the moment each one is complete, so the first can be
/// spoken while the rest is still arriving.
///
/// A sentence ends at `.`, `!`, `?` or `…` (plus any closing quotes or brackets) once the next
/// character turns out to be whitespace, or at a line break. Until that next character arrives we
/// can't tell "3." from "3.5", so a terminator at the very end of the text waits for more.
nonisolated struct SentenceSplitter {
    /// The very first piece may be cut at a comma, semicolon, colon or dash once it's at least this
    /// many characters long, so a long opening sentence starts playing sooner. nil turns that off.
    var eagerFirstClauseLength: Int?

    private(set) var pending = ""
    private var emittedAny = false

    init(eagerFirstClauseLength: Int? = 40) {
        self.eagerFirstClauseLength = eagerFirstClauseLength
    }

    /// Adds streamed text and returns every sentence it completed, trimmed, in order.
    mutating func append(_ text: String) -> [String] {
        pending += text
        var sentences: [String] = []
        while let cut = nextCut() {
            let index = pending.index(pending.startIndex, offsetBy: cut)
            let sentence = pending[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[index...])
            if !sentence.isEmpty {
                sentences.append(sentence)
                emittedAny = true
            }
        }
        return sentences
    }

    /// Call when the stream ends: returns whatever's left (an unterminated last sentence).
    mutating func finish() -> String? {
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if rest.isEmpty { return nil }
        emittedAny = true
        return rest
    }

    // MARK: - Finding the cut

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]
    /// Words that end in a full stop without ending the sentence ("Mr. Cann", "e.g. this").
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "e.g", "i.e", "approx", "no", "inc", "ltd",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "u.s", "u.k", "a.m", "p.m",
    ]

    /// How many characters of `pending` make up the next complete sentence, if there is one.
    private func nextCut() -> Int? {
        let chars = Array(pending)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                if chars[..<i].contains(where: { !$0.isWhitespace }) { return i + 1 }
            } else if Self.terminators.contains(c) {
                var j = i + 1
                while j < chars.count, Self.terminators.contains(chars[j]) || Self.closers.contains(chars[j]) {
                    j += 1
                }
                // Can't tell yet whether this ends the sentence ("3." might become "3.5")
                guard j < chars.count else { return nil }
                if chars[j].isWhitespace, !isAbbreviation(chars, stopAt: i) { return j }
                i = j
                continue
            }
            i += 1
        }
        return eagerClauseCut(chars)
    }

    private func isAbbreviation(_ chars: [Character], stopAt index: Int) -> Bool {
        guard chars[index] == "." else { return false }
        var start = index
        while start > 0, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
        let word = String(chars[start..<index])
        if Self.abbreviations.contains(word.lowercased()) { return true }
        // An initial, like the "J." in "J. Smith"
        if word.count == 1, word.first?.isUppercase == true { return true }
        // A list number on its own ("1. First, ...")
        let soFar = String(chars[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !soFar.isEmpty, soFar.count <= 3, soFar.allSatisfy(\.isNumber) { return true }
        return false
    }

    /// Only for the first piece of an answer: the first clause break past the threshold that's
    /// already followed by whitespace.
    private func eagerClauseCut(_ chars: [Character]) -> Int? {
        guard !emittedAny, let threshold = eagerFirstClauseLength, chars.count > threshold else { return nil }
        var i = threshold
        while i < chars.count - 1 {
            if Self.clauseBreaks.contains(chars[i]), chars[i + 1].isWhitespace { return i + 1 }
            i += 1
        }
        return nil
    }
}
