import Foundation

public struct StandingInstructionsResult: Sendable, Decodable {
    public var instructions: String
}

public extension RPCClient {
    /// His standing instructions for every session; with `text`, sets them.
    func standingInstructions(set text: String? = nil) async throws -> String {
        if let text {
            return try await call("instructions.set", .object(["text": .string(text)]), as: StandingInstructionsResult.self).instructions
        }
        return try await call("instructions.get", .object([:]), as: StandingInstructionsResult.self).instructions
    }
}
