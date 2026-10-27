import Foundation

/// Where the runner listens and the token to use, read from the runner's
/// data folder (`runner.json` and `secrets/runner-token`).
public struct RunnerEndpoint: Sendable, Equatable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }
}

public enum RunnerConfig {
    public static let defaultPort = 8797
    public static let launchdLabel = "com.mikerosoft.threadbear.runner"

    public static var defaultDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Threadbear", isDirectory: true)
    }

    /// The data folder: `--data-dir <path>`, then `THREADBEAR_DATA_DIR`, then
    /// the default. The override is how the mock runner and tests stay away
    /// from the real one.
    public static func dataDir(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let path = environment["THREADBEAR_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDataDir
    }

    public enum LoadError: Error, Equatable, LocalizedError {
        case missingToken(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken(let path): return "There's no runner token at \(path) yet."
            }
        }
    }

    public static func endpoint(dataDir: URL) throws -> RunnerEndpoint {
        var host = "127.0.0.1"
        var port = defaultPort
        let configURL = dataDir.appendingPathComponent("runner.json")
        if let data = try? Data(contentsOf: configURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = object["port"] as? Int { port = value }
            if let value = object["host"] as? String, !value.isEmpty { host = value }
        }
        let tokenURL = dataDir.appendingPathComponent("secrets/runner-token")
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            throw LoadError.missingToken(tokenURL.path)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw LoadError.missingToken(tokenURL.path) }
        return RunnerEndpoint(url: URL(string: "ws://\(host):\(port)/rpc")!, token: token)
    }
}

/// Reconnect delays: 0.25 s doubling to a 10 s ceiling.
public struct Backoff: Sendable {
    public var attempt = 0
    public var base: Double
    public var ceiling: Double

    public init(base: Double = 0.25, ceiling: Double = 10) {
        self.base = base
        self.ceiling = ceiling
    }

    public mutating func next() -> Double {
        defer { attempt += 1 }
        return min(ceiling, base * pow(2, Double(attempt)))
    }

    public mutating func reset() { attempt = 0 }
}
