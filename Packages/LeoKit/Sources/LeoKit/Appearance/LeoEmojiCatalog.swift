import Foundation

/// One emoji the picker offers: its CLDR name and English keywords.
public struct LeoEmojiEntry: Equatable, Hashable, Identifiable, Sendable {
    public let emoji: String
    public let name: String
    public let keywords: [String]
    /// A skin-toned form of another entry; hidden from the grid and from
    /// searches that don't ask for a tone.
    public let isSkinToneVariant: Bool

    public var id: String { emoji }

    /// Lowercased words of the name and keywords, for prefix search.
    fileprivate let nameWords: [String]
    fileprivate let keywordWords: [String]

    init(emoji: String, name: String, keywords: [String], isSkinToneVariant: Bool) {
        self.emoji = emoji
        self.name = name
        self.keywords = keywords
        self.isSkinToneVariant = isSkinToneVariant
        nameWords = Self.words(name)
        keywordWords = keywords.flatMap(Self.words)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// A CLDR group ("Smileys & Emotion"), base emoji only, in CLDR order.
public struct LeoEmojiGroup: Equatable, Identifiable, Sendable {
    public let name: String
    public let entries: [LeoEmojiEntry]

    public var id: String { name }
}

/// The agent-appearance picker's emoji: the fully-qualified Unicode set
/// (generated into `LeoEmojiCatalog+Data.swift` by
/// `scripts/gen-emoji-catalog.swift`), searchable by name and keyword.
public struct LeoEmojiCatalog: Sendable {
    public static let standard = LeoEmojiCatalog(data: generatedData, unicodeVersion: generatedUnicodeVersion)

    /// What the frequent row offers before the user has picked anything.
    public static let defaultFrequent = [
        "🤖", "🧠", "🛠️", "🚀", "🔥", "⭐", "🏛️", "🎩", "🧪", "📦", "🐙", "🦊", "🐝", "🌊", "🌲", "⚡", "💡", "🎯", "📚", "🔒",
    ]

    public let unicodeVersion: String
    /// Every entry, skin-toned variants included, in CLDR order.
    public let entries: [LeoEmojiEntry]
    public let groups: [LeoEmojiGroup]
    private let byEmoji: [String: LeoEmojiEntry]

    init(data: String, unicodeVersion: String) {
        var groups: [(name: String, entries: [LeoEmojiEntry])] = []
        var entries: [LeoEmojiEntry] = []
        for line in data.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "G" where fields.count >= 2:
                groups.append((fields[1], []))
            case "E" where fields.count >= 3, "T" where fields.count >= 3:
                let keywords = fields.count > 3 && !fields[3].isEmpty ? fields[3].components(separatedBy: "|") : []
                let entry = LeoEmojiEntry(emoji: fields[1], name: fields[2], keywords: keywords, isSkinToneVariant: fields[0] == "T")
                entries.append(entry)
                if !entry.isSkinToneVariant, !groups.isEmpty { groups[groups.count - 1].entries.append(entry) }
            default:
                continue
            }
        }
        self.unicodeVersion = unicodeVersion
        self.entries = entries
        self.groups = groups.map { LeoEmojiGroup(name: $0.name, entries: $0.entries) }
        byEmoji = Dictionary(entries.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func entry(for emoji: String) -> LeoEmojiEntry? { byEmoji[emoji] }

    /// Entries whose name or keywords have a word starting with every word
    /// of `query`, case-insensitively: an exact name first, then a name
    /// that starts with the query, then a name match, then keyword-only
    /// matches, each in CLDR order. Skin-toned variants only when the query
    /// asks for a tone.
    public func search(_ query: String, limit: Int = 300) -> [LeoEmojiEntry] {
        let tokens = LeoEmojiEntry.words(query)
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.joined(separator: " ")
        let wantsTones = tokens.contains { "tone".hasPrefix($0) && $0.count >= 3 || "skin".hasPrefix($0) && $0.count >= 3 }
        let ranked = entries.enumerated().compactMap { index, entry -> (rank: Int, index: Int, entry: LeoEmojiEntry)? in
            guard wantsTones || !entry.isSkinToneVariant else { return nil }
            let inName = tokens.allSatisfy { token in entry.nameWords.contains { $0.hasPrefix(token) } }
            let anywhere = inName || tokens.allSatisfy { token in
                entry.nameWords.contains { $0.hasPrefix(token) } || entry.keywordWords.contains { $0.hasPrefix(token) }
            }
            guard anywhere else { return nil }
            let name = entry.nameWords.joined(separator: " ")
            let rank = name == phrase ? 0 : name.hasPrefix(phrase) ? 1 : inName ? 2 : 3
            return (rank, index, entry)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.prefix(limit).map(\.entry)
    }

    /// The frequent row: `recent` picks first (newest first, as given),
    /// then the defaults, without repeats or emoji this catalog lacks.
    public func frequent(recent: [String], limit: Int = 16) -> [LeoEmojiEntry] {
        var seen = Set<String>()
        return (recent + Self.defaultFrequent)
            .filter { seen.insert($0).inserted }
            .compactMap(entry(for:))
            .prefix(limit)
            .map { $0 }
    }
}
