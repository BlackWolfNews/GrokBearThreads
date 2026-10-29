import Foundation

/// One entry of the server's `Server-Timing` header, e.g. `retrieve;dur=340`.
nonisolated struct ServerTimingEntry: Codable, Equatable, Hashable, Sendable {
    var name: String
    var durationMs: Double?
}

nonisolated enum ServerTiming {
    static let headerName = "Server-Timing"

    /// Parses `auth;dur=12, retrieve;dur=340`. Unknown parameters are ignored and a missing or
    /// unparseable `dur` gives a nil duration rather than dropping the entry.
    static func parse(_ header: String?) -> [ServerTimingEntry] {
        guard let header else { return [] }
        return header.split(separator: ",").compactMap { part in
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = fields.first, !name.isEmpty else { return nil }
            var duration: Double?
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                if pair.count == 2, pair[0].lowercased() == "dur" { duration = Double(pair[1]) }
            }
            return ServerTimingEntry(name: name, durationMs: duration)
        }
    }

    /// The server's own entries (auth, retrieve and whatever else it adds), without the ones
    /// Cloudflare appends on the way through (`cfExtPri`, `cfL4`, `cfEdge`, `cfOrigin`...), which
    /// aren't about our server and pushed the ones that are off the end of the row.
    static func ours(_ entries: [ServerTimingEntry]) -> [ServerTimingEntry] {
        entries.filter { !isCloudflare($0.name) }
    }

    /// Cloudflare names its entries "cf" then a capital or a digit; ours are lowercase words.
    static func isCloudflare(_ name: String) -> Bool {
        guard name.hasPrefix("cf"), let next = name.dropFirst(2).first else { return false }
        return next.isUppercase || next.isNumber
    }
}
