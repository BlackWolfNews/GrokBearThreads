import Foundation

/// An archive thread or web page an answer came from.
nonisolated struct AnswerSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    var title: String
    var threadId: String
    /// YYYY-MM-DD
    var date: String
    var url: String

    // Optional for stored/header sources from before web answers were supported.
    var kind: String? = nil

    var id: String { url }
    var isWeb: Bool { kind == "web" }
    var host: String { URL(string: url)?.host() ?? "" }

    static func fromEvent(_ value: Any) -> AnswerSource? {
        guard let entry = value as? [String: Any],
              let kind = entry["kind"] as? String, ["web", "archive"].contains(kind),
              let title = entry["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = entry["url"] as? String else { return nil }
        guard kind == "web" ? isPageURL(url) : URL(string: url)?.scheme != nil else { return nil }
        return AnswerSource(title: title, threadId: entry["threadId"] as? String ?? "",
                            date: entry["date"] as? String ?? "", url: url, kind: kind)
    }

    static func isPageURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return false }
        return true
    }

    static func merging(_ existing: [AnswerSource], _ incoming: [AnswerSource]) -> [AnswerSource] {
        var seen = Set<String>()
        return (existing + incoming).filter { seen.insert($0.url).inserted }
    }

    /// "23 Oct 2026", or the raw string if it isn't a plain date.
    var displayDate: String {
        guard let parsed = Self.dayFormatter.date(from: date) else { return date }
        return parsed.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

nonisolated enum SourcesHeader {
    static let name = "X-Quick-Sources"
    static let limit = 3

    /// Decodes the header: base64url (no padding) of UTF-8 JSON. Anything malformed gives [],
    /// and entries without a title or a URL are dropped rather than failing the lot.
    static func decode(_ header: String?) -> [AnswerSource] {
        guard let header, let data = base64URLDecode(header),
              let entries = try? JSONDecoder().decode([LenientSource].self, from: data) else { return [] }
        return AnswerSource.merging([], entries.compactMap { entry in
            guard let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let url = entry.url, URL(string: url)?.scheme != nil else { return nil }
            return AnswerSource(title: title, threadId: entry.threadId ?? "", date: entry.date ?? "", url: url)
        })
        .prefix(limit)
        .map { $0 }
    }

    /// For tests and the mock: the exact encoding the server uses.
    static func encode(_ sources: [AnswerSource]) -> String {
        let data = (try? JSONEncoder().encode(sources)) ?? Data("[]".utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private struct LenientSource: Decodable {
        var title: String?
        var threadId: String?
        var date: String?
        var url: String?
    }
}
