import XCTest
@testable import ThreadbearCore

final class SlashCommandsTests: XCTestCase {
    let commands = [
        SlashCommand(name: "model", description: "Switch this thread's model", argumentHint: "[model]", source: "threadbear"),
        SlashCommand(name: "effort", description: "Set this thread's effort level", source: "threadbear"),
        SlashCommand(name: "compact", description: "Free up context", source: "cli"),
        SlashCommand(name: "context", description: "What's using the context window", source: "cli"),
        SlashCommand(name: "code-review", description: "Review the diff", argumentHint: "[level] [target]", source: "skill"),
        SlashCommand(name: "deslop", description: "Clean up code", source: "skill"),
    ]

    func testQueryIsOnlyTheCommandBeingTyped() {
        XCTAssertEqual(SlashPalette.query(in: "/"), "")
        XCTAssertEqual(SlashPalette.query(in: "/co"), "co")
        XCTAssertNil(SlashPalette.query(in: "/compact now"), "arguments: the palette goes")
        XCTAssertNil(SlashPalette.query(in: "/Users/"), "a path")
        XCTAssertNil(SlashPalette.query(in: "/a\nb"))
        XCTAssertNil(SlashPalette.query(in: "hi /co"))
    }

    func testMatchesStartsWithThenContainsThenDescription() {
        let names = SlashPalette.matches(commands, query: "co", category: .all, recent: []).map(\.name)
        XCTAssertEqual(names, ["compact", "context", "code-review", "deslop"], "deslop by its description")
        XCTAssertEqual(SlashPalette.matches(commands, query: "", category: .skills, recent: []).map(\.name), ["code-review", "deslop"])
        XCTAssertEqual(SlashPalette.matches(commands, query: "", category: .cli, recent: []).map(\.name), ["compact", "context"])
    }

    func testRecentIsInTheOrderUsed() {
        let recent = SlashPalette.used("compact", recent: SlashPalette.used("deslop", recent: []))
        XCTAssertEqual(recent, ["compact", "deslop"])
        XCTAssertEqual(SlashPalette.matches(commands, query: "", category: .recent, recent: recent).map(\.name), ["compact", "deslop"])
        XCTAssertEqual(SlashPalette.used("deslop", recent: recent), ["deslop", "compact"])
    }

    func testCountsLeaveOutAnEmptyRecent() {
        let counts = SlashPalette.counts(commands, query: "", recent: [])
        XCTAssertEqual(counts.map(\.0), [.all, .threadbear, .cli, .skills])
        XCTAssertEqual(counts.map(\.1), [6, 2, 2, 2])
    }

    func testUsageAndFill() {
        XCTAssertEqual(commands[4].usage, "/code-review [level] [target]")
        XCTAssertEqual(commands[2].usage, "/compact")
        XCTAssertEqual(SlashPalette.fill(commands[4], forArguments: true), "/code-review ")
        XCTAssertEqual(SlashPalette.fill(commands[2], forArguments: false), "/compact")
    }

    func testDecodesTheRunnersList() throws {
        let json = #"{"commands":[{"name":"compact","source":"cli"},{"name":"x","description":"d","argumentHint":"<f>","source":"skill","extra":1}]}"#
        let list = try JSONDecoder().decode(SlashCommandList.self, from: Data(json.utf8))
        XCTAssertEqual(list.commands.map(\.name), ["compact", "x"])
        XCTAssertEqual(list.commands[1].argumentHint, "<f>")
        XCTAssertEqual(SlashPalette.Category.cli.title(provider: "codex"), "Codex")
    }

    func testOriginSaysWhereItCameFrom() {
        func origin(_ c: SlashCommand) -> String { SlashPalette.origin(of: c, provider: "claude") }
        XCTAssertEqual(origin(SlashCommand(name: "v", source: "skill", scope: "user", path: "/u/.claude/skills/v/SKILL.md")), "Your skill")
        XCTAssertEqual(origin(SlashCommand(name: "d", source: "skill", scope: "project", path: "/r/.claude/commands/d.md")), "This folder's command")
        XCTAssertEqual(origin(SlashCommand(name: "p", source: "skill", scope: "plugin", plugin: "ship-tools")), "From the ship-tools plugin")
        XCTAssertEqual(origin(SlashCommand(name: "x", source: "skill", scope: "claude.ai")), "Synced from claude.ai")
        XCTAssertEqual(origin(SlashCommand(name: "c", source: "cli", scope: "system")), "Claude Code's own")
        XCTAssertEqual(SlashPalette.shortPath("/Users/m/.claude/skills/v/SKILL.md", home: "/Users/m"), "~/.claude/skills/v/SKILL.md")
        XCTAssertEqual(SlashPalette.shortPath("/opt/x", home: "/Users/m"), "/opt/x")
    }
}
