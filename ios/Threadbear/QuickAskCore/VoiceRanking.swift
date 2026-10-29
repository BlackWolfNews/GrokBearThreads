import Foundation

/// The bits of an installed voice that matter for picking one, so the choice can be tested
/// without AVFoundation.
nonisolated struct VoiceInfo: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// BCP 47, e.g. en-AU
    var language: String
    /// 1 default, 2 enhanced, 3 premium (AVSpeechSynthesisVoiceQuality's raw values)
    var quality: Int
    var isNovelty = false
    var isPersonal = false

    var qualityLabel: String {
        switch quality {
        case 3: "Premium"
        case 2: "Enhanced"
        default: "Default"
        }
    }
}

nonisolated enum VoiceRanking {
    /// Australian and British English first (Mike's British and lives in Perth), then the rest.
    static let preferredLanguages = ["en-AU", "en-GB", "en-IE", "en-NZ", "en-US"]

    /// English voices worth offering, best first: premium over enhanced over default, and within
    /// a quality the preferred accents first. Novelty and Personal Voice are left out.
    static func ranked(_ voices: [VoiceInfo]) -> [VoiceInfo] {
        voices
            .filter { $0.language.lowercased().hasPrefix("en") && !$0.isNovelty && !$0.isPersonal }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let rankA = languageRank(a.language), rankB = languageRank(b.language)
                if rankA != rankB { return rankA < rankB }
                return a.name < b.name
            }
    }

    static func best(_ voices: [VoiceInfo]) -> VoiceInfo? { ranked(voices).first }

    private static func languageRank(_ language: String) -> Int {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        return preferredLanguages.firstIndex { $0.lowercased() == normalized } ?? preferredLanguages.count
    }
}
