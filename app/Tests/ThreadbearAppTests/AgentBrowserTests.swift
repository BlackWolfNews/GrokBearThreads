import Foundation
import Testing
@testable import Threadbear

/// The Browser panel's plain logic. The real checks need Chrome: they're in
/// BrowserBear's agent/agent-host.mjs comments and were run by hand, 5 Nov 2026.
struct AgentBrowserTests {
    @Test func aThreadsTabsDecodeFromTheHostsFile() throws {
        let json = """
        {"tabId":1004,"targetId":"AB","url":"https://example.com/","title":"Example","thread":"t1",
         "state":"yours","action":"over to you","finish":true,"status":"complete","handoffs":2,"openedAt":1,"popup":false}
        """
        let tab = try JSONDecoder().decode(AgentTab.self, from: Data(json.utf8))
        #expect(tab.tabId == 1004 && tab.thread == "t1" && tab.state == "yours" && tab.handoffs == 2)
    }

    /// Tabs a host wrote before it knew of a field, or that no thread owns.
    @Test func missingFieldsAreFine() throws {
        let json = #"{"tabId":1,"targetId":"A","url":"about:blank","title":""}"#
        let tab = try JSONDecoder().decode(AgentTab.self, from: Data(json.utf8))
        #expect(tab.thread == nil && tab.handoffs == nil)
    }

    @Test func keysGetTheNamesChromeWants() {
        #expect(KeyNames.lookup(0).0 == "KeyA" && KeyNames.lookup(0).1 == 65)
        #expect(KeyNames.lookup(51).0 == "Backspace")
        #expect(KeyNames.lookup(29).0 == "Digit0")
        #expect(KeyNames.code(forCharacter: "a") == 0)
        #expect(KeyNames.code(forCharacter: " ") == 49)
    }

    @Test func existingChromeTabsKeepTheirProfileAndThreadWithoutADebuggingPort() throws {
        let json = #"{"tabId":24,"url":"https://github.com/","title":"GitHub","thread":"t1","bridge":true,"profile":"personal-id","profileName":"Personal","profileEmail":"me@example.com"}"#
        let tab = try JSONDecoder().decode(AgentTab.self, from: Data(json.utf8))
        #expect(tab.bridge == true && tab.targetId == nil)
        #expect(tab.profile == "personal-id" && tab.profileTitle == "Personal · me@example.com")
    }
}
