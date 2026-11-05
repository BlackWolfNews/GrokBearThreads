import Foundation

/// One thing a thread made, shared or pinned for Mike (docs/protocol.md,
/// "Highlights"): a file, a link, a pull request or a commit. Read from
/// `threads.highlights`, so it doesn't scroll away with the transcript.
public struct Highlight: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: Sendable, Hashable, Codable {
        case file, link, pr, commit
        /// A kind this app doesn't know yet: shown as a link or a file if it
        /// has a url or a path, else left out (HighlightSections).
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "file": self = .file
            case "link": self = .link
            case "pr": self = .pr
            case "commit": self = .commit
            default: self = .other(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .file: "file"
            case .link: "link"
            case .pr: "pr"
            case .commit: "commit"
            case .other(let raw): raw
            }
        }
    }

    public enum How: Sendable, Hashable, Codable {
        case pinned, written, opened, mentioned, created, committed
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "pinned": self = .pinned
            case "written": self = .written
            case "opened": self = .opened
            case "mentioned": self = .mentioned
            case "created": self = .created
            case "committed": self = .committed
            default: self = .other(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .pinned: "pinned"
            case .written: "written"
            case .opened: "opened"
            case .mentioned: "mentioned"
            case .created: "created"
            case .committed: "committed"
            case .other(let raw): raw
            }
        }

        /// The word on a row: "Written", "Opened". Empty for one this app
        /// doesn't know, rather than a raw word it can't vouch for.
        public var word: String {
            switch self {
            case .pinned: "Pinned"
            case .written: "Written"
            case .opened: "Opened"
            case .mentioned: "Mentioned"
            case .created: "Created"
            case .committed: "Committed"
            case .other: ""
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String?
    /// A file's absolute path.
    public var path: String?
    public var how: How
    /// A pin's reason, in the agent's words.
    public var note: String?
    /// A pin the agent asked to have shown straight away.
    public var show: Bool
    /// A commit's short sha and branch, and whether a later push sent it.
    public var sha: String?
    public var branch: String?
    public var pushed: Bool
    /// The event it was first seen in (a pin: the thread's lastSeq then).
    public var seq: Int
    /// The latest event that mentioned it.
    public var lastSeq: Int
    public var at: Date?

    public init(id: String, kind: Kind, title: String, url: String? = nil, path: String? = nil, how: How = .mentioned,
                note: String? = nil, show: Bool = false, sha: String? = nil, branch: String? = nil, pushed: Bool = false,
                seq: Int = 0, lastSeq: Int? = nil, at: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.path = path
        self.how = how
        self.note = note
        self.show = show
        self.sha = sha
        self.branch = branch
        self.pushed = pushed
        self.seq = seq
        self.lastSeq = lastSeq ?? seq
        self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other("")
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        let title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        self.title = title ?? path.map { ($0 as NSString).lastPathComponent } ?? url ?? id
        how = (try? c.decodeIfPresent(How.self, forKey: .how)) ?? .mentioned
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        show = ((try? c.decodeIfPresent(Bool.self, forKey: .show)) ?? nil) ?? false
        sha = (try? c.decodeIfPresent(String.self, forKey: .sha)) ?? nil
        branch = (try? c.decodeIfPresent(String.self, forKey: .branch)) ?? nil
        pushed = ((try? c.decodeIfPresent(Bool.self, forKey: .pushed)) ?? nil) ?? false
        seq = c.lenientInt(forKey: .seq) ?? 0
        lastSeq = c.lenientInt(forKey: .lastSeq) ?? seq
        at = ((try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil).flatMap(ISO8601.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encode(how, forKey: .how)
        try c.encodeIfPresent(note, forKey: .note)
        if show { try c.encode(true, forKey: .show) }
        try c.encodeIfPresent(sha, forKey: .sha)
        try c.encodeIfPresent(branch, forKey: .branch)
        if pushed { try c.encode(true, forKey: .pushed) }
        try c.encode(seq, forKey: .seq)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encodeIfPresent(at.map(ISO8601.format), forKey: .at)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, url, path, how, note, show, sha, branch, pushed, seq, lastSeq, at
    }

    public var isPinned: Bool { how == .pinned }
    public var link: URL? { url.flatMap(URL.init(string:)) }
}

/// What `threads.highlights` answers: the highlights (pins first, then the
/// rest newest first), the files the thread edited, and the librarian's
/// line on where it's up to.
public struct ThreadHighlights: Sendable, Hashable, Codable {
    public struct Brief: Sendable, Hashable, Codable {
        public var text: String
        public var at: String?

        public init(text: String, at: String? = nil) {
            self.text = text
            self.at = at
        }
    }

    public var highlights: [Highlight]
    /// Absolute, newest first.
    public var edited: [String]
    public var brief: Brief?

    public init(highlights: [Highlight] = [], edited: [String] = [], brief: Brief? = nil) {
        self.highlights = highlights
        self.edited = edited
        self.brief = brief
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        highlights = c.lossyArray(Highlight.self, forKey: .highlights)
        edited = c.lossyArray(String.self, forKey: .edited)
        brief = (try? c.decodeIfPresent(Brief.self, forKey: .brief)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case highlights, edited, brief }
}

/// One row of a `list` panel, from `panels.render`.
public struct PanelItem: Sendable, Hashable, Codable {
    public enum Tone: String, Sendable, Hashable, Codable {
        case attention, failed, done
    }

    public var title: String
    /// Grey, under the title, up to two lines.
    public var detail: String?
    public var url: String?
    public var path: String?
    /// An SF Symbol name.
    public var icon: String?
    /// Nil is plain, and so is a tone this app doesn't know.
    public var tone: Tone?
    /// A heading over this row and the next ones with the same section,
    /// drawn where it changes.
    public var section: String?
    /// Short and faint at the end of the title's line: a date or a count.
    public var trailing: String?

    public init(title: String, detail: String? = nil, url: String? = nil, path: String? = nil, icon: String? = nil, tone: Tone? = nil,
                section: String? = nil, trailing: String? = nil) {
        self.title = title
        self.detail = detail
        self.url = url
        self.path = path
        self.icon = icon
        self.tone = tone
        self.section = section
        self.trailing = trailing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)) ?? nil
        section = (try? c.decodeIfPresent(String.self, forKey: .section)) ?? nil
        trailing = (try? c.decodeIfPresent(String.self, forKey: .trailing)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case title, detail, url, path, icon, tone, section, trailing }
}

extension PanelItem {
    /// The heading to draw over each row: its section where it differs from
    /// the row before's, so a patch's groups come out in its own order.
    public static func headings(_ items: [PanelItem]) -> [String?] {
        var last: String?
        return items.map { item in
            defer { last = item.section }
            guard let section = item.section, !section.isEmpty, section != last else { return nil }
            return section
        }
    }
}
