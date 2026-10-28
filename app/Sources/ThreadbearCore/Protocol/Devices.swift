import Foundation

/// A phone or browser that reads the mirror (docs/protocol.md, "Devices"):
/// one phone token each, which the runner issues, lists and revokes for
/// the Settings window's Phone & browser tab. Decoded forgivingly: a field
/// an older runner leaves out takes its default.
public struct Device: Sendable, Hashable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case phone, browser
        /// A kind this app doesn't know, from a newer runner.
        case other
    }

    /// The token's id, for revoking.
    public var id: String
    public var kind: Kind
    /// "iPhone", "Chrome": what was paired, as the app named it.
    public var name: String
    public var createdAt: Date?
    public var expiresAt: Date?
    public var expired: Bool

    public init(id: String, kind: Kind, name: String, createdAt: Date? = nil, expiresAt: Date? = nil, expired: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.expired = expired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil).flatMap(Kind.init(rawValue:)) ?? .other
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil).flatMap(ISO8601.parse)
        expiresAt = ((try? c.decodeIfPresent(String.self, forKey: .expiresAt)) ?? nil).flatMap(ISO8601.parse)
        expired = (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? false
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, createdAt, expiresAt, expired }
}

/// `devices.list` and `devices.revoke`: the devices, the website's root
/// while sync is on, or why nothing can pair while it's off.
public struct DeviceList: Sendable, Equatable, Decodable {
    public var devices: [Device]
    public var site: String?
    public var reason: String?

    public init(devices: [Device] = [], site: String? = nil, reason: String? = nil) {
        self.devices = devices
        self.site = site
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = c.lossyArray(Device.self, forKey: .devices)
        site = ((try? c.decodeIfPresent(String.self, forKey: .site)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey { case devices, site, reason }
}

/// `devices.pair`: the new device and the one link that carries its token,
/// a `threadbear://pair` link to draw as a QR code for a phone, or the
/// website's sign-in link to open for a browser. Shown or opened once and
/// then forgotten: never logged, never kept.
public struct DevicePairing: Sendable, Equatable, Decodable {
    public var device: Device
    public var pairingLink: URL?
    public var signInLink: URL?

    public init(device: Device, pairingLink: URL? = nil, signInLink: URL? = nil) {
        self.device = device
        self.pairingLink = pairingLink
        self.signInLink = signInLink
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(Device.self, forKey: .device)
        pairingLink = ((try? c.decodeIfPresent(String.self, forKey: .pairingLink)) ?? nil).flatMap(URL.init(string:))
        signInLink = ((try? c.decodeIfPresent(String.self, forKey: .signInLink)) ?? nil).flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey { case device, pairingLink, signInLink }
}

public extension RPCClient {
    func devicesList() async throws -> DeviceList {
        try await call("devices.list", .object([:]), as: DeviceList.self)
    }

    /// Issues a token for a new phone or browser; `days` is the runner's
    /// default (90) when nil.
    func devicesPair(kind: Device.Kind, name: String? = nil, days: Int? = nil) async throws -> DevicePairing {
        var params: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let days { params["days"] = .number(Double(days)) }
        return try await call("devices.pair", .object(params), as: DevicePairing.self)
    }

    func devicesRevoke(_ id: String) async throws -> DeviceList {
        try await call("devices.revoke", .object(["deviceId": .string(id)]), as: DeviceList.self)
    }
}

public enum DeviceText {
    /// The line under a device's name: when it was paired and how long its
    /// token lasts, or that it has run out. "Paired 28 Oct, until 26 Jan"
    /// or "Expired 26 Jan: pair it again".
    public static func detail(_ device: Device, now: Date = Date(), calendar: Calendar = .current) -> String {
        if device.expired || (device.expiresAt.map { $0 < now } ?? false) {
            return device.expiresAt.map { "Expired \(day($0, now: now, calendar: calendar)): pair it again" } ?? "Expired: pair it again"
        }
        var parts: [String] = []
        if let createdAt = device.createdAt { parts.append("Paired \(day(createdAt, now: now, calendar: calendar))") }
        if let expiresAt = device.expiresAt { parts.append((parts.isEmpty ? "Until " : "until ") + day(expiresAt, now: now, calendar: calendar)) }
        return parts.joined(separator: ", ")
    }

    /// "28 Oct", with the year once it isn't this one.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }
}
