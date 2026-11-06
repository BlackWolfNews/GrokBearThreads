import Foundation

/// A command the composer's palette offers (docs/protocol.md, "Slash
/// commands"), as `threads.commands` lists it for a thread.
public struct SlashCommand: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var description: String?
    public var argumentHint: String?
    /// "threadbear", "cli" or "skill"; anything newer counts as the CLI's.
    public var source: String
    /// Other names that run it (/usage is /cost and /stats too).
    public var aliases: [String]?
    /// Where it was defined: "user", "project", "plugin" (with `plugin`),
    /// "claude.ai", "system", or one this app doesn't know.
    public var scope: String?
    public var plugin: String?
    /// Its file on the runner's machine, when the runner found it.
    public var path: String?

    public var id: String { name }

    public init(name: String, description: String? = nil, argumentHint: String? = nil, source: String,
                aliases: [String]? = nil, scope: String? = nil, plugin: String? = nil, path: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.aliases = aliases
        self.scope = scope
        self.plugin = plugin
        self.path = path
    }

    /// What to type, with its arguments: "/code-review [low|medium|high] [target]".
    public var usage: String {
        guard let hint = argumentHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty else { return "/\(name)" }
        return "/\(name) \(hint)"
    }

    public var isSkill: Bool { source == "skill" }
    public var isThreadbear: Bool { source == "threadbear" }
}

public struct SlashCommandList: Sendable, Codable {
    public var commands: [SlashCommand]
}

/// The palette that opens over the composer when a message starts with
/// "/" (mockup C, picked on 6 Nov): categories down the side, the matches,
/// and the one picked described in full.
public enum SlashPalette {
    public enum Category: String, CaseIterable, Sendable {
        case all, threadbear, cli, skills, recent

        /// The CLI's own are named after it ("Claude Code", "Codex").
        public func title(provider: String) -> String {
            switch self {
            case .all: "All"
            case .threadbear: "Threadbear"
            case .cli: cliName(provider)
            case .skills: "Skills"
            case .recent: "Recent"
            }
        }
    }

    public static func cliName(_ provider: String) -> String {
        provider == "codex" ? "Codex" : "Claude Code"
    }

    /// The command being typed, without its slash, while the message is
    /// only that: "/", "/co". Nil once there's a space (its arguments), a
    /// second line, or a second slash (a path, "/Users/").
    public static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return String(rest)
    }

    /// Where a command came from, for the detail pane.
    public static func origin(of command: SlashCommand, provider: String) -> String {
        if command.isThreadbear { return "Threadbear's own: it changes this thread's settings" }
        let kind = command.path.map { $0.hasSuffix("/SKILL.md") ? "skill" : "command" } ?? (command.isSkill ? "skill" : "command")
        switch command.scope {
        case "user": return "Your \(kind)"
        case "project", "repo": return "This folder's \(kind)"
        case "plugin": return command.plugin.map { "From the \($0) plugin" } ?? "From a plugin"
        case "claude.ai": return "Synced from claude.ai"
        case "admin": return "Set up by your organisation"
        case "system": return "\(cliName(provider))'s own"
        default: return command.isSkill ? "A skill" : "\(cliName(provider))'s own"
        }
    }

    /// A path to show: the home folder as ~.
    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func inCategory(_ command: SlashCommand, _ category: Category, recent: [String]) -> Bool {
        switch category {
        case .all: true
        case .threadbear: command.isThreadbear
        case .cli: !command.isThreadbear && !command.isSkill
        case .skills: command.isSkill
        case .recent: recent.contains(command.name)
        }
    }

    /// The matches for what's typed: names that start with it first, then
    /// names that contain it, then ones whose description does, each in
    /// the runner's order. Recent is in the order they were used.
    public static func matches(_ commands: [SlashCommand], query: String, category: Category, recent: [String]) -> [SlashCommand] {
        let q = query.lowercased()
        let pool = commands.filter { inCategory($0, category, recent: recent) }
        func rank(_ c: SlashCommand) -> Int? {
            let name = c.name.lowercased()
            if q.isEmpty || name.hasPrefix(q) { return 0 }
            if name.contains(q) { return 1 }
            if c.description?.lowercased().contains(q) == true { return 2 }
            return nil
        }
        var ranked = pool.enumerated().compactMap { i, c in rank(c).map { (rank: $0, order: i, command: c) } }
        if category == .recent {
            ranked = ranked.map { ($0.rank, recent.firstIndex(of: $0.command.name) ?? $0.order, $0.command) }
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.command)
    }

    /// How many each category has for what's typed. Recent and the CLI's
    /// own are left out where there are none: a thread with nothing used
    /// yet has no Recent to click.
    public static func counts(_ commands: [SlashCommand], query: String, recent: [String]) -> [(Category, Int)] {
        Category.allCases.compactMap { cat in
            let n = matches(commands, query: query, category: cat, recent: recent).count
            if cat == .recent, recent.isEmpty { return nil }
            return (cat, n)
        }
    }

    /// The text a pick leaves in the box: the command, and a space when
    /// its arguments are to be typed next.
    public static func fill(_ command: SlashCommand, forArguments: Bool) -> String {
        forArguments ? "/\(command.name) " : "/\(command.name)"
    }

    /// The recently used list after using `name`: newest first, eight kept.
    public static func used(_ name: String, recent: [String]) -> [String] {
        Array(([name] + recent.filter { $0 != name }).prefix(8))
    }
}
