import Foundation

/// Mike's Connectors gateway, as the runner last heard from its /health
/// (docs/protocol.md, "Connectors"): `connectors.status` and
/// `connectors.updated`. Read leniently, as the gateway's answer is still
/// changing: an unknown state is shown as it is.
public struct ConnectorsStatus: Sendable, Hashable, Decodable {
    /// ok, unreachable, off or checking.
    public var state: String
    public var url: String?
    public var checkedAt: Date?
    public var error: String?
    public var version: String?
    public var services: [ConnectorService]

    public init(state: String = "ok", url: String? = nil, checkedAt: Date? = nil, error: String? = nil, version: String? = nil, services: [ConnectorService] = []) {
        self.state = state
        self.url = url
        self.checkedAt = checkedAt
        self.error = error
        self.version = version
        self.services = services
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "checking"
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        checkedAt = ((try? c.decodeIfPresent(String.self, forKey: .checkedAt)) ?? nil).flatMap(ConnectorsStatus.parseDate)
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        services = c.lossyArray(ConnectorService.self, forKey: .services)
    }

    enum CodingKeys: String, CodingKey { case state, url, checkedAt, error, version, services }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public struct ConnectorService: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var title: String
    /// connected, signed_out, connecting, error, disabled or unknown (or a
    /// newer word).
    public var state: String
    public var message: String?
    public var connectUrl: String?

    public init(id: String, title: String, state: String, message: String? = nil, connectUrl: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.message = message
        self.connectUrl = connectUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? id
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "unknown"
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
        connectUrl = (try? c.decodeIfPresent(String.self, forKey: .connectUrl)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case id, title, state, message, connectUrl }
}

public struct ConnectorsResult: Sendable, Decodable {
    public var connectors: ConnectorsStatus
}
