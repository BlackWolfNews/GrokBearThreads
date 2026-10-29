import AppIntents
import Foundation

/// Opens Threadbear's quick ask, already listening. It's what the Action button, Siri, Spotlight and
/// Back Tap (through Shortcuts) run.
nonisolated struct QuickAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick ask"
    static let description = IntentDescription("Opens Threadbear listening for a question, and answers it out loud from your Agent Archive.")

    /// iOS 18. From iOS 26 `supportedModes` takes over.
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        let time = Date().timeIntervalSince1970
        await QuickAskIntentBridge.performed(at: time)
        return .result()
    }
}

/// How the intent reaches the running app, and when it ran (for press-to-mic timing).
@MainActor
enum QuickAskIntentBridge {
    static var lastPerformedAt: Double?
    static var handler: ((Double) -> Void)?

    static func performed(at time: Double) {
        lastPerformedAt = time
        handler?(time)
    }
}

/// Puts "Quick ask" in Settings › Action Button › Shortcut, in Siri and in Spotlight, with no
/// setup in the Shortcuts app.
nonisolated struct ThreadbearShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickAskIntent(),
            phrases: [
                "Quick ask \(.applicationName)",
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Quick ask",
            systemImageName: "waveform"
        )
    }
}
