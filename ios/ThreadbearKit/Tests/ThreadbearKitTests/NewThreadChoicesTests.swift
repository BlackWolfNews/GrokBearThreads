import Foundation
import Testing
@testable import ThreadbearKit

@Suite struct NewThreadChoicesTests {
    @Test func accountsDecodeWithAndWithoutModels() throws {
        let json = #"""
        [{"id":"claude-3","provider":"claude","title":"three@example.com","usage":{"windows":[],"readAt":"x","source":"live"},
          "models":[{"id":"opus","title":"Opus 5.5","effortLevels":["low","high","max"]}],"defaultEffort":"high"},
         {"id":"codex-main","provider":"codex","title":"Codex · me"}]
        """#
        let accounts = try JSONDecoder().decode([PhoneAccount].self, from: Data(json.utf8))
        #expect(accounts.map(\.id) == ["claude-3", "codex-main"])
        #expect(accounts[0].models == [PhoneModelChoice(id: "opus", title: "Opus 5.5", effortLevels: ["low", "high", "max"])])
        #expect(accounts[1].models.isEmpty)
    }

    @Test func modelsComeClaudeFirstAndOnceEach() {
        let accounts = [
            PhoneAccount(id: "codex-main", provider: "codex", title: "C", models: [PhoneModelChoice(id: "astra", title: "Astra")]),
            PhoneAccount(id: "claude-1", provider: "claude", title: "1", models: [PhoneModelChoice(id: "opus", title: "Opus"), PhoneModelChoice(id: "haiku", title: "Haiku")]),
            PhoneAccount(id: "claude-2", provider: "claude", title: "2", models: [PhoneModelChoice(id: "opus", title: "Opus")]),
        ]
        #expect(NewThreadChoices.models(accounts).map(\.id) == ["opus", "haiku", "astra"])
    }

    @Test func effortsFollowTheModel() {
        let codex = PhoneModelChoice(id: "astra", title: "Astra", effortLevels: ["low", "medium", "ultra", "weird"])
        #expect(NewThreadChoices.efforts(for: codex) == ["low", "medium", "ultra"])
        #expect(NewThreadChoices.efforts(for: nil) == ["low", "medium", "high", "xhigh", "max"])
        #expect(NewThreadChoices.keeps(effort: "ultra", model: codex))
        #expect(!NewThreadChoices.keeps(effort: "ultra", model: nil))
        #expect(NewThreadChoices.keeps(effort: nil, model: nil))
        #expect(NewThreadChoices.effortTitle("xhigh") == "Extra high")
    }
}
