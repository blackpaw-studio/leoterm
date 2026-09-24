import Foundation

/// B-009: the sidebar filter's fuzzy matching. Pure -- no model or view --
/// so ranking is unit-testable on its own.
///
/// A query matches a candidate when its characters appear in order,
/// case-insensitively. Both sides are Unicode case-folded, which can expand
/// one character into several ("ß" → "ss", "ﬁ" → "fi"), so matching runs on
/// the folded units; offsets map back to whole `Character`s, what the user
/// sees. Better-shaped matches rank first.
enum LeoFuzzyMatcher {
    /// Best first.
    enum Tier: Int, Comparable, Sendable {
        case exact, prefix, wordBoundary, substring, subsequence

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match: Equatable, Sendable {
        let tier: Tier
        /// `Character` offsets into the candidate that the query matched.
        let offsets: [Int]
    }

    /// A piece of a name, drawn bold when `isMatched`.
    struct HighlightRun: Equatable, Sendable {
        let text: String
        let isMatched: Bool
    }

    static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Folded(query).units
        let haystack = Folded(candidate)
        guard !needle.isEmpty, needle.count <= haystack.units.count else { return nil }
        if needle == haystack.units { return Match(tier: .exact, offsets: haystack.characters(haystack.units.indices)) }

        let starts = contiguousStarts(of: needle, in: haystack.units)
        let characters = Array(candidate)
        let contiguous = { (tier: Tier, start: Int) in
            Match(tier: tier, offsets: haystack.characters(start..<(start + needle.count)))
        }
        if starts.first == 0 { return contiguous(.prefix, 0) }
        if let start = starts.first(where: {
            haystack.startsCharacter($0) && isWordStart(characters, at: haystack.owners[$0])
        }) { return contiguous(.wordBoundary, start) }
        if let start = starts.first { return contiguous(.substring, start) }
        return subsequenceUnits(of: needle, in: haystack.units).map {
            Match(tier: .subsequence, offsets: haystack.characters($0))
        }
    }

    /// Rows matching `query` on their name or template, best match first;
    /// ties keep the incoming (sidebar) order. An empty query changes
    /// nothing.
    static func rank(_ rows: [LeoAgentRow], query: String) -> [LeoAgentRow] {
        let needle = trimmed(query)
        guard !needle.isEmpty else { return rows }
        return rows.enumerated()
            .compactMap { index, row in sortKey(for: row, query: needle).map { (key: $0, index: index, row: row) } }
            .sorted { ($0.key, $0.index) < ($1.key, $1.index) }
            .map(\.row)
    }

    /// The name characters to draw bold for `query`.
    static func nameHighlights(for row: LeoAgentRow, query: String) -> [Int] {
        match(trimmed(query), in: row.name)?.offsets ?? []
    }

    static func highlightRuns(name: String, offsets: [Int]) -> [HighlightRun] {
        let matched = Set(offsets)
        var runs: [HighlightRun] = []
        var current = ""
        var currentMatched = false
        for (index, character) in name.enumerated() {
            let isMatched = matched.contains(index)
            if isMatched != currentMatched, !current.isEmpty {
                runs.append(HighlightRun(text: current, isMatched: currentMatched))
                current = ""
            }
            currentMatched = isMatched
            current.append(character)
        }
        if !current.isEmpty { runs.append(HighlightRun(text: current, isMatched: currentMatched)) }
        return runs
    }

    // MARK: Private

    private static let wordSeparators: Set<Character> = ["-", "_", ".", " "]

    /// Tier first; at the same tier a name match beats a template match.
    private static func sortKey(for row: LeoAgentRow, query: String) -> Int? {
        let nameKey = match(query, in: row.name).map { $0.tier.rawValue * 2 }
        let templateKey = row.template.flatMap { match(query, in: $0) }.map { $0.tier.rawValue * 2 + 1 }
        return [nameKey, templateKey].compactMap { $0 }.min()
    }

    private static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text case-folded into comparable units, each remembering which
    /// original `Character` it came from.
    private struct Folded {
        let units: [Character]
        /// `owners[i]` is the offset of the `Character` that `units[i]` folded from.
        let owners: [Int]

        init(_ text: String) {
            let pairs = text.enumerated().flatMap { offset, character in
                String(character).folding(options: .caseInsensitive, locale: nil).map { (unit: $0, owner: offset) }
            }
            units = pairs.map(\.unit)
            owners = pairs.map(\.owner)
        }

        /// Whether `unit` is the first unit of its `Character`.
        func startsCharacter(_ unit: Int) -> Bool { unit == 0 || owners[unit - 1] != owners[unit] }

        /// The distinct `Character` offsets the given units belong to, in order.
        func characters(_ unitIndices: some Sequence<Int>) -> [Int] {
            unitIndices.reduce(into: [Int]()) { offsets, unit in
                if offsets.last != owners[unit] { offsets.append(owners[unit]) }
            }
        }
    }

    private static func contiguousStarts(of needle: [Character], in haystack: [Character]) -> [Int] {
        (0...(haystack.count - needle.count)).filter { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// After a separator, or a lower-to-upper camel hump.
    private static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return wordSeparators.contains(previous) || (previous.isLowercase && characters[index].isUppercase)
    }

    /// Leftmost greedy: each query unit takes the first match after the
    /// previous one.
    private static func subsequenceUnits(of needle: [Character], in haystack: [Character]) -> [Int]? {
        var offsets: [Int] = []
        var position = 0
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            offsets.append(found)
            position = found + 1
        }
        return offsets
    }
}
