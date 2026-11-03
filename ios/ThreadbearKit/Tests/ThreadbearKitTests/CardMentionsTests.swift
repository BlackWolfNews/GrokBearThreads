import Foundation
import Testing
@testable import ThreadbearKit

struct CardMentionsTests {
    @Test func onlyNotionLinksAreCards() {
        let text = "Look at [Fix \\[the\\] button](https://app.notion.com/p/abc123) and [Docs](https://example.com/x)"
        let found = CardMentions.find(in: text)
        #expect(found.map(\.title) == ["Fix [the] button"])
        #expect(found.first?.url == "https://app.notion.com/p/abc123")
        #expect(CardMentions.find(in: "![a picture](https://www.notion.so/t3)").isEmpty)
        #expect(CardMentions.find(in: "[c](https://notion.so.evil.com/t3) [d](http://www.notion.so/t3)").isEmpty)
    }
}
