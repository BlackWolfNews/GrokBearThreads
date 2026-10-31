import Foundation

/// A card in the Pocket (backend API 19): something an agent filed for when
/// Mike's out, from the `pocket` tool. `id` is its title in lower case.
public struct PocketCard: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    /// What to search the map for, to tell whether the card applies here.
    public var place: String?
    public var threadId: String?
    /// The project or thread it came from.
    public var source: String?
    public var updatedAt: String

    public init(id: String, title: String, text: String, place: String? = nil, threadId: String? = nil, source: String? = nil, updatedAt: String) {
        self.id = id
        self.title = title
        self.text = text
        self.place = place
        self.threadId = threadId
        self.source = source
        self.updatedAt = updatedAt
    }
}

public enum PocketDeck {
    /// Back of the deck to front. The front card is the one shown whole, so
    /// that's where a card for here goes, then the newest.
    public static func ordered(_ cards: [PocketCard], here: Set<String> = []) -> [PocketCard] {
        cards.sorted { a, b in
            let (hereA, hereB) = (here.contains(a.id), here.contains(b.id))
            if hereA != hereB { return hereB }
            return a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt < b.updatedAt
        }
    }
}

/// The cards as last seen, in a file, as the Pocket is for places with no
/// signal: the app has them before it's connected to anything.
public struct PocketStore: Sendable {
    public var file: URL

    public init(file: URL) { self.file = file }

    public static var standard: PocketStore {
        let folder = URL.applicationSupportDirectory
        return PocketStore(file: folder.appending(path: "pocket.json"))
    }

    public func load() -> [PocketCard] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([PocketCard].self, from: data)) ?? []
    }

    public func save(_ cards: [PocketCard]) {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // These can be addresses and booking codes: locked with the phone,
        // and kept out of its backups.
        #if os(iOS)
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: file, options: .atomic)
        #endif
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
