import Foundation

public extension RPCClient {
    /// Pending reviews can outlive the transcript's newest loaded page.
    /// Listing them lets the header reopen a request without paging back
    /// through every tool event since it was created.
    func pendingReviews(threadId: String) async throws -> [DesignReview] {
        try await call("reviews.list", .object(["threadId": .string(threadId)]), as: PendingReviewsResult.self).reviews
    }

    func createReview(threadId: String, title: String, note: String? = nil, options: [ReviewOptionInput]) async throws -> DesignReview {
        var params: [String: JSONValue] = ["threadId": .string(threadId), "title": .string(title), "options": .array(options.map(\.jsonValue))]
        if let note { params["note"] = .string(note) }
        return try await call("reviews.create", .object(params), as: ReviewReply.self).review
    }

    func review(threadId: String, reviewId: String) async throws -> DesignReview {
        try await call("reviews.get", .object(["threadId": .string(threadId), "reviewId": .string(reviewId)]), as: ReviewReply.self).review
    }

    func saveReview(threadId: String, reviewId: String, revision: Int, draft: ReviewDraft) async throws -> DesignReview {
        try await call("reviews.save", reviewParams(threadId: threadId, reviewId: reviewId, revision: revision, draft: draft), as: ReviewReply.self).review
    }

    func respondReview(threadId: String, reviewId: String, revision: Int, draft: ReviewDraft) async throws -> ReviewReply {
        try await call("reviews.respond", reviewParams(threadId: threadId, reviewId: reviewId, revision: revision, draft: draft), as: ReviewReply.self)
    }

    func cancelReview(threadId: String, reviewId: String, revision: Int) async throws -> DesignReview {
        try await call("reviews.cancel", reviewParams(threadId: threadId, reviewId: reviewId, revision: revision), as: ReviewReply.self).review
    }

    private func reviewParams(threadId: String, reviewId: String, revision: Int, draft: ReviewDraft? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["threadId": .string(threadId), "reviewId": .string(reviewId), "revision": .number(Double(revision))]
        if let draft { params["draft"] = draft.jsonValue }
        return .object(params)
    }
}

private struct PendingReviewsResult: Sendable, Decodable {
    var reviews: [DesignReview]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviews = c.lossyArray(DesignReview.self, forKey: .reviews)
    }

    enum CodingKeys: String, CodingKey { case reviews }
}
