import Foundation
import ThreadbearCore

extension AppModel {
    /// Saves his standing instructions. Nil when it worked, else why not.
    func saveStandingInstructions(_ text: String) async -> String? {
        guard let client, connection == .connected else { return "Not connected to the runner." }
        do {
            standingInstructions = try await client.standingInstructions(set: text)
            return nil
        } catch RPCError.server(_, let message) {
            return message
        } catch {
            return error.localizedDescription
        }
    }
}
