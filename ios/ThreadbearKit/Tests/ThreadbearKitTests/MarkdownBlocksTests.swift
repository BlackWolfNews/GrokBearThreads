import Testing
@testable import ThreadbearKit

@Suite struct MarkdownBlocksTests {
    @Test func tablesBecomeRowsAndCells() {
        let blocks = MarkdownBlock.parse("""
        Here's the spread:

        | Option | Cost | Notes |
        |:--|:-:|--:|
        | **A** | $5 | fast \\| cheap |
        | B | $9 |
        """)
        #expect(blocks == [
            .paragraph("Here's the spread:"),
            .table(header: ["Option", "Cost", "Notes"], alignments: [.leading, .center, .trailing], rows: [
                ["**A**", "$5", "fast | cheap"],
                ["B", "$9", ""],
            ]),
        ])
    }

    @Test func aPipeInProseIsNotATable() {
        #expect(MarkdownBlock.parse("Use a | b here\nand carry on") == [.paragraph("Use a | b here and carry on")])
    }

    @Test func nestedListsKeepTheirDepth() {
        let blocks = MarkdownBlock.parse("""
        - one
          - one a
            - one a i
        - two
        1. first
        2) second
        + plus
        """)
        #expect(blocks == [
            .listItem(text: "one", marker: "•", depth: 0, task: nil),
            .listItem(text: "one a", marker: "•", depth: 1, task: nil),
            .listItem(text: "one a i", marker: "•", depth: 2, task: nil),
            .listItem(text: "two", marker: "•", depth: 0, task: nil),
            .listItem(text: "first", marker: "1.", depth: 0, task: nil),
            .listItem(text: "second", marker: "2.", depth: 0, task: nil),
            .listItem(text: "plus", marker: "•", depth: 0, task: nil),
        ])
    }

    @Test func aWrappedListItemStaysOneItem() {
        let blocks = MarkdownBlock.parse("""
        - **Tables** show up as raw
          pipes on the phone.
        - Quotes too.

          A second paragraph in it.

        After the list.
        """)
        #expect(blocks == [
            .listItem(text: "**Tables** show up as raw pipes on the phone.", marker: "•", depth: 0, task: nil),
            .listItem(text: "Quotes too.\n\nA second paragraph in it.", marker: "•", depth: 0, task: nil),
            .paragraph("After the list."),
        ])
    }

    @Test func taskListsHaveTheirBoxes() {
        #expect(MarkdownBlock.parse("- [ ] todo\n- [x] done") == [
            .listItem(text: "todo", marker: "•", depth: 0, task: false),
            .listItem(text: "done", marker: "•", depth: 0, task: true),
        ])
    }

    @Test func quotesRulesAndHeadings() {
        let blocks = MarkdownBlock.parse("""
        ## What I found ##
        > It's **broken**
        > - on the phone
        ---
        * * *
        Done
        """)
        #expect(blocks == [
            .heading(level: 2, text: "What I found"),
            .quote([.paragraph("It's **broken**"), .listItem(text: "on the phone", marker: "•", depth: 0, task: nil)]),
            .rule,
            .rule,
            .paragraph("Done"),
        ])
    }

    @Test func codeFencesKeepTheirInsides() {
        let blocks = MarkdownBlock.parse("""
        1. Run it:
           ```sh
           tb land
             --dry-run
           ```
        ~~~
        | not a table |
        |---|
        ~~~
        """)
        #expect(blocks == [
            .listItem(text: "Run it:", marker: "1.", depth: 0, task: nil),
            .code("tb land\n  --dry-run"),
            .code("| not a table |\n|---|"),
        ])
    }

    @Test func paragraphsJoinSoftBreaksAndKeepHardOnes() {
        #expect(MarkdownBlock.parse("one\ntwo  \nthree\\\nfour\n\nnext") == [
            .paragraph("one two\nthree\nfour"),
            .paragraph("next"),
        ])
    }

    @Test func anUnclosedFenceWhileStreamingIsStillCode() {
        #expect(MarkdownBlock.parse("Look:\n```\nlet a = 1") == [.paragraph("Look:"), .code("let a = 1")])
    }
}
