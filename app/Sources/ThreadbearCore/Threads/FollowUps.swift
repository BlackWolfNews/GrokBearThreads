import Foundation

/// The done card's follow-ups (end_turn's `next`) as toggles on the
/// composer's text. Mike found one-at-a-time buttons that only ever added
/// text unclear when he wanted several (30 Oct): now a click puts its
/// words in the box, another takes them out, and the card ticks whichever
/// are in there, typed changes included.
public enum FollowUps {
    /// The follow-ups whose words are in `draft`.
    public static func picked(in draft: String, next: [String]) -> Set<Int> {
        Set(next.indices.filter { i in
            let text = next[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && draft.contains(text)
        })
    }

    /// `draft` with `text` taken out when it's there, or added on a
    /// paragraph of its own after what's typed when it isn't.
    public static func toggled(_ text: String, in draft: String) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = typed.range(of: text) else { return typed.isEmpty ? text : typed + "\n\n" + text }
        var rest = typed.replacingCharacters(in: range, with: "")
        // Taking a paragraph out of the middle leaves two gaps; one is enough.
        while rest.contains("\n\n\n") { rest = rest.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
