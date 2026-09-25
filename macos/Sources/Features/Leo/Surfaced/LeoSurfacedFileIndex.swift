import Foundation

/// The selected host's surfaced files (B-013), by incarnation: a file
/// attaches to a row only when both carry the same name *and* `started_at`
/// (D-074/D-075), never by name alone. A file that arrives before the list
/// shows its incarnation waits here until it does. A file is its
/// incarnation plus its id: ids are unique within an incarnation, and a
/// new incarnation reusing one is another file. Bounded: each incarnation keeps its newest
/// `perIncarnationLimit`, and the index its `incarnationLimit` most
/// recently touched incarnations.
struct LeoSurfacedFileIndex: Equatable, Sendable {
    static let perIncarnationLimit = 20
    static let incarnationLimit = 64
    static let empty = LeoSurfacedFileIndex(files: [:], recency: [])

    private struct Incarnation: Hashable, Sendable {
        let name: String
        let startedAt: String
    }

    /// Newest last.
    private let files: [Incarnation: [LeoSurfacedFile]]
    /// Least recently touched first.
    private let recency: [Incarnation]

    func files(name: String, startedAt: String?) -> [LeoSurfacedFile] {
        guard let startedAt else { return [] }
        return files[Incarnation(name: name, startedAt: startedAt)] ?? []
    }

    func attach(to rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.map { $0.withSurfacedFiles(files(name: $0.name, startedAt: $0.startedAt)) }
    }

    /// A live event's file. With an `at`, it goes before the first entry
    /// with a later one (a delayed event never lands as newest), and one
    /// older than everything in a full incarnation is dropped rather than
    /// evicting a newer file; without, it's appended as the newest.
    /// `isNew` is false (and the index unchanged) for a file already known
    /// or dropped.
    func inserting(_ file: LeoSurfacedFile) -> (index: LeoSurfacedFileIndex, isNew: Bool) {
        let key = Incarnation(name: file.agent, startedAt: file.startedAt)
        let known = files[key] ?? []
        guard !known.contains(where: { $0.id == file.id }) else { return (self, false) }
        guard Self.position(of: file, in: known) > 0 || known.count < Self.perIncarnationLimit else { return (self, false) }
        return (replacing(key, with: Self.placing(known, file)), true)
    }

    /// Recovery from `/state`: each incarnation's reported list (newest
    /// last) is authoritative for order. Entries filed under an
    /// incarnation other than the agent's own are ignored; a full baseline
    /// whose entries were all ignored is an empty full baseline. See
    /// `eventOnly(_:after:)` for files only a live event reported.
    func merging(state: [LeoObservedAgent]) -> LeoSurfacedFileIndex {
        state.reduce(self) { index, agent in
            guard let startedAt = agent.startedAt else { return index }
            let key = Incarnation(name: agent.name, startedAt: startedAt)
            let known = index.files[key] ?? []
            let reported = Self.unique(agent.surfacedFiles.filter { $0.agent == agent.name && $0.startedAt == startedAt })
            let isFull = agent.surfacedFilesSent >= Self.perIncarnationLimit
            guard !reported.isEmpty || (isFull && !known.isEmpty) else { return index }
            let reportedIDs = Set(reported.map(\.id))
            let eventOnly = known.filter { !reportedIDs.contains($0.id) }
            return index.replacing(key, with: Self.eventOnly(eventOnly, after: reported, isFull: isFull).reduce(reported, Self.placing))
        }
    }

    /// Files a live event reported but `/state`'s `baseline` didn't.
    /// `isFull`: the daemon sent its cap's worth, counted before any entry
    /// was filtered out. Below the cap the baseline held everything it had, so they came
    /// after the fetch: kept, placed by `at` like a live event (B-046). A full baseline can't tell a newer
    /// file from an older one that fell out of its window, so only files
    /// whose `at` is later than every baseline `at` stay; the rest are
    /// dropped rather than promoted to newest (the next `/state` restores
    /// any that were newer).
    private static func eventOnly(_ files: [LeoSurfacedFile], after baseline: [LeoSurfacedFile], isFull: Bool) -> [LeoSurfacedFile] {
        guard isFull else { return files }
        guard let newest = baseline.compactMap({ date($0.at) }).max() else { return [] }
        return files.filter { date($0.at).map { $0 > newest } ?? false }
    }

    /// `file` inserted before the first entry with a later `at`; without
    /// an `at`, appended as the newest.
    private static func placing(_ list: [LeoSurfacedFile], _ file: LeoSurfacedFile) -> [LeoSurfacedFile] {
        let position = position(of: file, in: list)
        return Array(list[..<position]) + [file] + Array(list[position...])
    }

    private static func position(of file: LeoSurfacedFile, in list: [LeoSurfacedFile]) -> Int {
        date(file.at).flatMap { at in list.firstIndex { date($0.at).map { $0 > at } ?? false } } ?? list.endIndex
    }

    private static func date(_ at: String?) -> Date? {
        guard let at else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: at) ?? fractional.date(from: at)
    }

    private func replacing(_ key: Incarnation, with list: [LeoSurfacedFile]) -> LeoSurfacedFileIndex {
        let recency = recency.filter { $0 != key } + [key]
        let evicted = Set(recency.dropLast(Self.incarnationLimit))
        var files = files.filter { !evicted.contains($0.key) }
        files[key] = Array(list.suffix(Self.perIncarnationLimit))
        return LeoSurfacedFileIndex(files: files, recency: Array(recency.suffix(Self.incarnationLimit)))
    }

    private static func unique(_ list: [LeoSurfacedFile]) -> [LeoSurfacedFile] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }
}
