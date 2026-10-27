import Foundation

/// The runner's settings, as the Settings window shows them
/// (docs/protocol.md, "Settings and models"). Everything is kept in the
/// runner's runner.json except the OpenRouter key, which the app never
/// sees: only whether one is set and its last few characters. Decoded as
/// forgivingly as the other models, so a missing field takes its default.
public struct RunnerSettings: Sendable, Hashable, Decodable {
    public struct Key: Sendable, Hashable, Decodable {
        public var set: Bool
        /// The key's last 4 characters, to tell keys apart.
        public var hint: String?

        public init(set: Bool = false, hint: String? = nil) {
            self.set = set
            self.hint = hint
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            set = (try? c.decodeIfPresent(Bool.self, forKey: .set)) ?? false
            hint = (try? c.decodeIfPresent(String.self, forKey: .hint)).flatMap { $0.isEmpty ? nil : $0 }
        }

        enum CodingKeys: String, CodingKey { case set, hint }
    }

    public struct Models: Sendable, Hashable, Decodable {
        public var openRouterKey: Key
        /// 0 turns model calls off.
        public var dailyBudgetUsd: Double
        public var spentTodayUsd: Double
        public var spentMonthUsd: Double
        /// Folders whose thread text is never sent, as written ("~/" kept).
        public var privateFolders: [String]

        public init(openRouterKey: Key = Key(), dailyBudgetUsd: Double = 1, spentTodayUsd: Double = 0,
                    spentMonthUsd: Double = 0, privateFolders: [String] = []) {
            self.openRouterKey = openRouterKey
            self.dailyBudgetUsd = dailyBudgetUsd
            self.spentTodayUsd = spentTodayUsd
            self.spentMonthUsd = spentMonthUsd
            self.privateFolders = privateFolders
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            openRouterKey = (try? c.decodeIfPresent(Key.self, forKey: .openRouterKey)) ?? Key()
            dailyBudgetUsd = c.number(.dailyBudgetUsd) ?? 1
            spentTodayUsd = c.number(.spentTodayUsd) ?? 0
            spentMonthUsd = c.number(.spentMonthUsd) ?? 0
            privateFolders = c.lossyArray(String.self, forKey: .privateFolders)
        }

        enum CodingKeys: String, CodingKey { case openRouterKey, dailyBudgetUsd, spentTodayUsd, spentMonthUsd, privateFolders }
    }

    public var defaultCwd: String
    public var idleMinutes: Int
    public var maxLiveCLIs: Int
    /// Takes effect when the runner next restarts.
    public var followMain: Bool
    public var models: Models

    public init(defaultCwd: String = "", idleMinutes: Int = 30, maxLiveCLIs: Int = 6, followMain: Bool = true, models: Models = Models()) {
        self.defaultCwd = defaultCwd
        self.idleMinutes = idleMinutes
        self.maxLiveCLIs = maxLiveCLIs
        self.followMain = followMain
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultCwd = (try? c.decodeIfPresent(String.self, forKey: .defaultCwd)) ?? ""
        idleMinutes = c.number(.idleMinutes).map { Int($0.rounded()) } ?? 30
        maxLiveCLIs = c.number(.maxLiveCLIs).map { Int($0.rounded()) } ?? 6
        followMain = (try? c.decodeIfPresent(Bool.self, forKey: .followMain)) ?? true
        models = (try? c.decodeIfPresent(Models.self, forKey: .models)) ?? Models()
    }

    enum CodingKeys: String, CodingKey { case defaultCwd, idleMinutes, maxLiveCLIs, followMain, models }
}

/// Fields for `settings.update`; nil ones are left out, so an edit to one
/// field never overwrites another a second client just changed.
public struct SettingsUpdate: Sendable, Hashable {
    public var defaultCwd: String?
    public var idleMinutes: Int?
    public var maxLiveCLIs: Int?
    public var followMain: Bool?
    public var dailyBudgetUsd: Double?
    public var privateFolders: [String]?

    public init(defaultCwd: String? = nil, idleMinutes: Int? = nil, maxLiveCLIs: Int? = nil, followMain: Bool? = nil,
                dailyBudgetUsd: Double? = nil, privateFolders: [String]? = nil) {
        self.defaultCwd = defaultCwd
        self.idleMinutes = idleMinutes
        self.maxLiveCLIs = maxLiveCLIs
        self.followMain = followMain
        self.dailyBudgetUsd = dailyBudgetUsd
        self.privateFolders = privateFolders
    }

    public var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let defaultCwd { params["defaultCwd"] = .string(defaultCwd) }
        if let idleMinutes { params["idleMinutes"] = .number(Double(idleMinutes)) }
        if let maxLiveCLIs { params["maxLiveCLIs"] = .number(Double(maxLiveCLIs)) }
        if let followMain { params["followMain"] = .bool(followMain) }
        var models: [String: JSONValue] = [:]
        if let dailyBudgetUsd { models["dailyBudgetUsd"] = .number(dailyBudgetUsd) }
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

    /// Sends the key once; the runner keeps it and only ever says whether
    /// one is set. Nil removes it.
    func settingsSetKey(provider: String = "openrouter", key: String?) async throws -> RunnerSettings {
        let params: JSONValue = .object(["provider": .string(provider), "key": key.map { .string($0) } ?? .null])
        return try await call("settings.setKey", params, as: SettingsResult.self).settings
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
    /// Spend in dollars: "$0.42", "$0", and "under $0.01" for the fractions
    /// of a cent a few small calls cost, which "$0.00" would hide.
    public static func money(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "$0" }
        if usd < 0.01 { return "under $0.01" }
        return String(format: "$%.2f", usd)
    }

    /// A folder as Mike would write it: "~/dev/x" for one in his home.
    public static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
