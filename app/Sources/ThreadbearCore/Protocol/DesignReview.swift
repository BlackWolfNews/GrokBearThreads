import Foundation

/// A draft is saved separately from submission: closing a review must never
/// turn an unfinished choice or note into a message to the agent.
public struct ReviewDraft: Sendable, Hashable, Codable {
    public var pickedId: String?
    public var notes: [String: String]

    public init(pickedId: String? = nil, notes: [String: String] = [:]) {
        self.pickedId = pickedId
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pickedId = try c.decodeIfPresent(String.self, forKey: .pickedId)
        notes = (try? c.decodeIfPresent([String: String].self, forKey: .notes)) ?? [:]
    }

    public var hasNotes: Bool {
        notes.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The runner validates again. This only keeps the Send button from
    /// offering an empty reply or a pick that cannot be made.
    public func canSubmit(options: [ReviewOption]) -> Bool {
        let ids = Set(options.map(\.id))
        guard notes.allSatisfy({ ids.contains($0.key) && $0.value.utf16.count <= 4000 }) else { return false }
        if let pickedId {
            guard options.contains(where: { $0.id == pickedId && !$0.reference }) else { return false }
        }
        return pickedId != nil || hasNotes
    }

    public var jsonValue: JSONValue {
        var value: [String: JSONValue] = ["notes": .object(notes.mapValues(JSONValue.string))]
        if let pickedId { value["pickedId"] = .string(pickedId) }
        return .object(value)
    }

    enum CodingKeys: String, CodingKey { case pickedId, notes }
}

public struct ReviewOption: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var note: String?
    public var reference: Bool
    public var image: ImageRef

    public init(id: String, title: String, note: String? = nil, reference: Bool = false, image: ImageRef) {
        self.id = id
        self.title = title
        self.note = note
        self.reference = reference
        self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        note = try c.decodeIfPresent(String.self, forKey: .note)
        reference = (try? c.decodeIfPresent(Bool.self, forKey: .reference)) ?? false
        image = try c.decode(ImageRef.self, forKey: .image)
    }

    enum CodingKeys: String, CodingKey { case id, title, note, reference, image }
}

/// The latest persisted snapshot of a review. Status stays a string so a
/// newer runner can add a terminal state without making the card disappear.
/// Only the exact status "pending" can be edited by this client.
public struct DesignReview: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var note: String?
    public var options: [ReviewOption]
    public var status: String
    public var revision: Int
    public var createdAt: String
    public var updatedAt: String
    public var draft: ReviewDraft
    public var response: ReviewDraft?
    public var replyTurnId: String?

    public init(id: String, title: String, note: String? = nil, options: [ReviewOption], status: String = "pending",
                revision: Int = 1, createdAt: String = "", updatedAt: String = "", draft: ReviewDraft = ReviewDraft(),
                response: ReviewDraft? = nil, replyTurnId: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.options = options
        self.status = status
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draft = draft
        self.response = response
        self.replyTurnId = replyTurnId
    }

    public var isPending: Bool { status == "pending" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Design options"
        note = try c.decodeIfPresent(String.self, forKey: .note)
        options = c.lossyArray(ReviewOption.self, forKey: .options)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        revision = c.lenientInt(forKey: .revision) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        draft = try c.decodeIfPresent(ReviewDraft.self, forKey: .draft) ?? ReviewDraft()
        response = try c.decodeIfPresent(ReviewDraft.self, forKey: .response)
        replyTurnId = try c.decodeIfPresent(String.self, forKey: .replyTurnId)
    }

    enum CodingKeys: String, CodingKey { case id, title, note, options, status, revision, createdAt, updatedAt, draft, response, replyTurnId }
}

/// Creation takes source paths; the runner replaces these with imported
/// ImageRefs before it publishes a review.
public struct ReviewOptionInput: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var path: String
    public var note: String?
    public var reference: Bool

    public init(id: String, title: String, path: String, note: String? = nil, reference: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.note = note
        self.reference = reference
    }

    public var jsonValue: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "title": .string(title), "path": .string(path)]
        if let note { fields["note"] = .string(note) }
        if reference { fields["reference"] = .bool(true) }
        return .object(fields)
    }
}

public struct ReviewReply: Sendable, Hashable, Decodable {
    public var review: DesignReview
    public var turnId: String?

    public init(review: DesignReview, turnId: String? = nil) {
        self.review = review
        self.turnId = turnId
    }
}

/// Mike's answer to a review, read back out of the message the runner sent
/// for it (`reviewReply` in runner/src/reviews.ts), so his bubble can say
/// what he picked instead of showing the review's id and the agent-facing
/// wording (Mike, 29 Oct). The runner only puts the review's id and his
/// draft on the event, not the option titles, hence reading the text.
public struct ReviewAnswer: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        /// Small and quiet, over the line: what it's about.
        public var label: String
        /// In his own words' style: what he picked or wrote.
        public var text: String
    }

    public var lines: [Line]

    /// Nil when the text isn't the runner's wording for this review and
    /// draft, so the bubble shows it as it is.
    public static func parse(_ text: String, reviewId: String?, response: ReviewDraft?) -> ReviewAnswer? {
        guard let reviewId, let response else { return nil }
        var rest = Substring(text)
        // "Review: <title> (<id>)"
        let head = " (\(reviewId))"
        guard rest.hasPrefix("Review: "), let close = rest.range(of: head) else { return nil }
        let title = String(rest[rest.index(rest.startIndex, offsetBy: 8)..<close.lowerBound])
        rest = rest[close.upperBound...]
        var lines: [Line] = []
        // "Picked <id>. <option title>."
        if let picked = response.pickedId {
            guard rest.hasPrefix("\n\nPicked \(picked). ") else { return nil }
            rest = rest.dropFirst("\n\nPicked \(picked). ".count)
            let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
            var option = rest[..<end]
            if option.hasSuffix(".") { option = option.dropLast() }
            lines.append(Line(label: title, text: "Picked \(picked): \(Self.bare(option, id: picked))"))
            rest = rest[end...]
        }
        // "Notes on <id> (<option title>): <note>", in the review's option
        // order, which the draft doesn't keep, so whichever comes next.
        var notes = response.notes.filter { !$0.value.isEmpty }
        while !notes.isEmpty {
            guard let (id, note) = notes.first(where: { rest.hasPrefix("\n\nNotes on \($0.key) (") }) else { return nil }
            rest = rest.dropFirst("\n\nNotes on \(id) (".count)
            guard let tail = rest.range(of: "): " + note) else { return nil }
            let option = rest[..<tail.lowerBound]
            // With nothing picked, the review's title goes over the first one.
            lines.append(Line(label: (lines.isEmpty ? title + "\n" : "") + "Notes on \(id): \(Self.bare(option, id: id))", text: note))
            rest = rest[tail.upperBound...]
            notes[id] = nil
        }
        return rest.isEmpty && !lines.isEmpty ? ReviewAnswer(lines: lines) : nil
    }

    /// Agents often title options "A: Summary first", which would read
    /// "Picked A: A: Summary first".
    static func bare(_ option: Substring, id: String) -> Substring {
        for sep in [": ", ". ", " - ", ") "] where option.hasPrefix(id + sep) && option.count > id.count + sep.count {
            return option.dropFirst(id.count + sep.count)
        }
        return option
    }
}
