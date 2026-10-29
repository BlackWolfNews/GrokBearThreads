import Testing
@testable import QuickAskCore

struct SpokenReplyTests {
    @Test func markdownMarksGo() {
        let text = "## Drives\n\nIt's **CannMedia**, the `8 TB` one.\n- one\n- two\n> quoted"
        #expect(SpokenReply.text(from: text) == "Drives. It's CannMedia, the 8 TB one. one. two. quoted.")
    }

    @Test func codeBlocksAreLeftOutAndSaidSo() {
        let text = "Run this:\n```\nnpm test\n```\nThen check."
        #expect(SpokenReply.text(from: text) == "Run this: There's some code on screen. Then check.")
    }

    @Test func linksSayTheirTextAndURLsTheirHost() {
        let text = "See [the plan](https://example.com/plan) or https://bruce.tail9ef766.ts.net:9443/?thread=x."
        #expect(SpokenReply.text(from: text) == "See the plan or bruce.tail9ef766.ts.net.")
    }

    @Test func longRepliesStopAtASentence() {
        let text = String(repeating: "This is a sentence. ", count: 200)
        let spoken = SpokenReply.text(from: text, limit: 100)
        #expect(spoken.count <= 140)
        #expect(spoken.hasSuffix("The rest is on screen."))
    }

    @Test func emptyStaysEmpty() {
        #expect(SpokenReply.text(from: "  \n ") == "")
    }
}
