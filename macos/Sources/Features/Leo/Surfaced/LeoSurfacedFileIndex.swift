import Foundation

/// The selected host's surfaced files (B-013), by incarnation: a file
/// attaches to a row only when both carry the same name *and* `started_at`
/// (D-074/D-075), never by name alone. A file that arrives before the list
/// shows its incarnation waits here until it does. Ids are unique across
/// the index. Bounded: each incarnation keeps its newest
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

    /// A live event's file, appended as the newest. `isNew` is false (and
    /// the index unchanged) for an id already known.
    func inserting(_ file: LeoSurfacedFile) -> (index: LeoSurfacedFileIndex, isNew: Bool) {
        guard !contains(file.id) else { return (self, false) }
        let key = Incarnation(name: file.agent, startedAt: file.startedAt)
        return (replacing(key, with: (files[key] ?? []) + [file]), true)
    }

    /// Recovery from `/state`: each incarnation's reported list (newest
    /// last) is authoritative for order; files only a live event reported
    /// -- newer than the fetch -- stay after it. Entries filed under an
    /// incarnation other than the agent's own are ignored.
    func merging(state: [LeoObservedAgent]) -> LeoSurfacedFileIndex {
        state.reduce(self) { index, agent in
            let reported = agent.surfacedFiles.filter { $0.agent == agent.name && $0.startedAt == agent.startedAt }
            guard let first = reported.first else { return index }
            let key = Incarnation(name: first.agent, startedAt: first.startedAt)
            // An id already filed under another incarnation stays there.
            let elsewhere = index.files.filter { $0.key != key }.values.flatMap { $0 }.map(\.id)
            let ordered = Self.unique(reported.filter { !elsewhere.contains($0.id) })
            let reportedIDs = Set(ordered.map(\.id))
            let liveOnly = (index.files[key] ?? []).filter { !reportedIDs.contains($0.id) }
            return index.replacing(key, with: ordered + liveOnly)
        }
    }

    private func contains(_ id: String) -> Bool {
        files.values.contains { $0.contains { $0.id == id } }
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
