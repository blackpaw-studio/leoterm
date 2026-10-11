import Foundation
import OSLog

/// Which surfaced files the user has opened, per host (B-013), so a
/// `/state` recovery never re-badges them. A file is its incarnation
/// (agent + `started_at`) plus its id: a new incarnation reusing an id is
/// another file. Each host keeps its latest `perHostLimit`, oldest first.
public struct LeoSurfacedFileLedger: Equatable, Sendable, Codable {
    public static let perHostLimit = 200

    private struct Entry: Equatable, Hashable, Sendable, Codable {
        let agent: String
        let startedAt: String
        let id: String

        init(_ file: LeoSurfacedFile) {
            agent = file.agent
            startedAt = file.startedAt
            id = file.id
        }
    }

    /// Keyed by `hostKey`; a Codable map with string keys stays a plain
    /// JSON object.
    private let seen: [String: [Entry]]

    public init() { seen = [:] }

    private init(seen: [String: [Entry]]) { self.seen = seen }

    public func isSeen(_ file: LeoSurfacedFile, host: LeoHostID) -> Bool {
        seen[Self.hostKey(host)]?.contains(Entry(file)) ?? false
    }

    public func markingSeen(_ file: LeoSurfacedFile, host: LeoHostID) -> LeoSurfacedFileLedger {
        guard !isSeen(file, host: host) else { return self }
        let key = Self.hostKey(host)
        let entries = Array(((seen[key] ?? []) + [Entry(file)]).suffix(Self.perHostLimit))
        return LeoSurfacedFileLedger(seen: seen.merging([key: entries]) { _, new in new })
    }

    private static func hostKey(_ host: LeoHostID) -> String {
        switch host {
        case .local: "local"
        case .remote(let name): "remote:\(name)"
        }
    }
}

public protocol LeoSurfacedFileSeenStore {
    func load() -> LeoSurfacedFileLedger
    func save(_ ledger: LeoSurfacedFileLedger)
}

/// The ledger as JSON under one key. Unreadable data reads as nothing
/// seen: at worst a file badges again. v2: entries are keyed by
/// incarnation + id (the id-only v1 key is ignored).
public final class LeoUserDefaultsSurfacedFileSeenStore: LeoSurfacedFileSeenStore {
    public static let key = "leo.surfacedFiles.seen.v2"
    private static var logger: Logger { LeoLog.logger() }
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> LeoSurfacedFileLedger {
        guard let data = defaults.data(forKey: Self.key) else { return LeoSurfacedFileLedger() }
        do {
            return try JSONDecoder().decode(LeoSurfacedFileLedger.self, from: data)
        } catch {
            Self.logger.error("surfaced-file seen ids unreadable: \(error.localizedDescription, privacy: .public)")
            return LeoSurfacedFileLedger()
        }
    }

    public func save(_ ledger: LeoSurfacedFileLedger) {
        do {
            defaults.set(try JSONEncoder().encode(ledger), forKey: Self.key)
        } catch {
            Self.logger.error("surfaced-file seen ids not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

public final class LeoInMemorySurfacedFileSeenStore: LeoSurfacedFileSeenStore {
    private var ledger = LeoSurfacedFileLedger()

    public init() {}

    public func load() -> LeoSurfacedFileLedger { ledger }
    public func save(_ ledger: LeoSurfacedFileLedger) { self.ledger = ledger }
}
