import Foundation

/// The runner's settings, as the Settings window shows them
/// (docs/protocol.md, "Settings and models"), all kept in the runner's
/// runner.json. Decoded as forgivingly as the other models, so a missing
/// field takes its default and an older runner's OpenRouter fields (key,
/// budget, spend) are ignored.
public struct RunnerSettings: Sendable, Hashable, Decodable {
    public struct Models: Sendable, Hashable, Decodable {
        /// The pool whose Claude logins answer small jobs (titles, the
        /// librarian); nil means none, so those are off.
        public var pool: String?
        /// Whether the runner sends `pool` at all. A much older one doesn't.
        public var poolSupported: Bool
        /// Folders whose thread text is never sent, as written ("~/" kept).
        public var privateFolders: [String]

        public init(pool: String? = nil, poolSupported: Bool = false, privateFolders: [String] = []) {
            self.pool = pool
            self.poolSupported = poolSupported
            self.privateFolders = privateFolders
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            poolSupported = c.contains(.pool)
            pool = ((try? c.decodeIfPresent(String.self, forKey: .pool)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            privateFolders = c.lossyArray(String.self, forKey: .privateFolders)
        }

        enum CodingKeys: String, CodingKey { case pool, privateFolders }
    }

    public var defaultCwd: String
    public var idleMinutes: Int
    public var maxLiveCLIs: Int
    /// Takes effect when the runner next restarts.
    public var followMain: Bool
    /// A turn's reply: end_turn's bullets, or (false) the agent's own message.
    public var bulletReplies: Bool
    public var models: Models

    public init(defaultCwd: String = "", idleMinutes: Int = 30, maxLiveCLIs: Int = 6, followMain: Bool = true, bulletReplies: Bool = true, models: Models = Models()) {
        self.defaultCwd = defaultCwd
        self.idleMinutes = idleMinutes
        self.maxLiveCLIs = maxLiveCLIs
        self.followMain = followMain
        self.bulletReplies = bulletReplies
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultCwd = (try? c.decodeIfPresent(String.self, forKey: .defaultCwd)) ?? ""
        idleMinutes = c.number(.idleMinutes).map { Int($0.rounded()) } ?? 30
        maxLiveCLIs = c.number(.maxLiveCLIs).map { Int($0.rounded()) } ?? 6
        followMain = (try? c.decodeIfPresent(Bool.self, forKey: .followMain)) ?? true
        bulletReplies = (try? c.decodeIfPresent(Bool.self, forKey: .bulletReplies)) ?? true
        models = (try? c.decodeIfPresent(Models.self, forKey: .models)) ?? Models()
    }

    enum CodingKeys: String, CodingKey { case defaultCwd, idleMinutes, maxLiveCLIs, followMain, bulletReplies, models }
}

/// Fields for `settings.update`; nil ones are left out, so an edit to one
/// field never overwrites another a second client just changed.
public struct SettingsUpdate: Sendable, Hashable {
    public var defaultCwd: String?
    public var idleMinutes: Int?
    public var maxLiveCLIs: Int?
    public var followMain: Bool?
    public var bulletReplies: Bool?
    /// `.some(nil)` sends null: no pool, so no small jobs.
    public var pool: String??
    public var privateFolders: [String]?

    public init(defaultCwd: String? = nil, idleMinutes: Int? = nil, maxLiveCLIs: Int? = nil, followMain: Bool? = nil, bulletReplies: Bool? = nil,
                pool: String?? = nil, privateFolders: [String]? = nil) {
        self.pool = pool
        self.defaultCwd = defaultCwd
        self.idleMinutes = idleMinutes
        self.maxLiveCLIs = maxLiveCLIs
        self.followMain = followMain
        self.bulletReplies = bulletReplies
        self.privateFolders = privateFolders
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let defaultCwd { params["defaultCwd"] = .string(defaultCwd) }
        if let idleMinutes { params["idleMinutes"] = .number(Double(idleMinutes)) }
        if let maxLiveCLIs { params["maxLiveCLIs"] = .number(Double(maxLiveCLIs)) }
        if let followMain { params["followMain"] = .bool(followMain) }
        if let bulletReplies { params["bulletReplies"] = .bool(bulletReplies) }
        var models: [String: JSONValue] = [:]
        if let pool { models["pool"] = pool.map { .string($0) } ?? .null }
        if let privateFolders { models["privateFolders"] = .array(privateFolders.map { .string($0) }) }
        if !models.isEmpty { params["models"] = .object(models) }
        return params
    }
}

public struct SettingsResult: Sendable, Decodable {
    public var settings: RunnerSettings
}

public extension RPCClient {
    func settingsGet() async throws -> RunnerSettings {
        try await call("settings.get", .object([:]), as: SettingsResult.self).settings
    }

    func settingsUpdate(_ update: SettingsUpdate) async throws -> RunnerSettings {
        try await call("settings.update", .object(update.params), as: SettingsResult.self).settings
    }
}

private extension KeyedDecodingContainer {
    /// A number sent as a number or a numeric string.
    func number(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}

public enum SettingsText {
    /// A folder as Mike would write it: "~/dev/x" for one in his home.
    public static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
