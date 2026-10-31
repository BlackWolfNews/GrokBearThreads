import Foundation
import Testing
@testable import ThreadbearKit

@Suite struct PocketTests {
    private func card(_ id: String, _ at: String, place: String? = nil) -> PocketCard {
        PocketCard(id: id, title: id, text: "t", place: place, updatedAt: at)
    }

    @Test func newestGoesToTheFront() {
        let deck = PocketDeck.ordered([card("b", "2026-10-02"), card("c", "2026-10-03"), card("a", "2026-10-01")])
        #expect(deck.map(\.id) == ["a", "b", "c"])
    }

    @Test func aCardForHereBeatsANewerOne() {
        let deck = PocketDeck.ordered([card("old", "2026-10-01", place: "post office"), card("new", "2026-10-03")], here: ["old"])
        #expect(deck.last?.id == "old")
    }

    @Test func savedCardsComeBackWithNoBackend() throws {
        let store = PocketStore(file: FileManager.default.temporaryDirectory.appending(path: "pocket-\(UUID()).json"))
        #expect(store.load().isEmpty)
        let cards = [card("a", "2026-10-01", place: "post office")]
        store.save(cards)
        #expect(store.load() == cards)
        store.clear()
        #expect(store.load().isEmpty)
    }

    @Test func aDamagedFileIsNoCards() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "pocket-\(UUID()).json")
        try Data("nope".utf8).write(to: file)
        #expect(PocketStore(file: file).load().isEmpty)
    }

    @Test func decodesWhatThePhoneQueryAnswers() throws {
        let json = #"[{"id":"a","title":"A","text":"x","updatedAt":"2026-10-01"}]"#
        let cards = try JSONDecoder().decode([PocketCard].self, from: Data(json.utf8))
        #expect(cards.map(\.title) == ["A"])
        #expect(cards[0].threadId == nil)
    }

    @Test func removingGoesStraightToTheBackend() async throws {
        let transport = RecordingTransport()
        try await ConvexBackend(transport: transport, token: "tb_x").removePocketCard(id: "a")
        let call = transport.calls.withLock { $0.first }
        #expect(call?.0 == "phone:removePocketCard")
        #expect(call?.1["id"] == .string("a"))
    }

    @Test func fakeBackendRemovesACard() async throws {
        let fake = FakeBackend()
        try await fake.removePocketCard(id: FakeBackend.samplePocket[0].id)
        for try await cards in fake.pocket() {
            #expect(cards.count == FakeBackend.samplePocket.count - 1)
            break
        }
    }
}
