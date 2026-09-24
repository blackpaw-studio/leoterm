import Foundation
import OSLog

/// Which surfaced-file ids the user has opened, per host (B-013), so a
/// `/state` recovery never re-badges them. Each host keeps its latest
/// `perHostLimit` ids, oldest first.
struct LeoSurfacedFileLedger: Equatable, Sendable, Codable {
    static let perHostLimit = 200

    /// Keyed by `hostKey`; a Codable map with string keys stays a plain
    /// JSON object.
    private let seen: [String: [String]]

    init() { seen = [:] }

    private init(seen: [String: [String]]) { self.seen = seen }

    func isSeen(_ id: String, host: LeoHostID) -> Bool {
        seen[Self.hostKey(host)]?.contains(id) ?? false
    }

    func markingSeen(_ id: String, host: LeoHostID) -> LeoSurfacedFileLedger {
        guard !isSeen(id, host: host) else { return self }
        let key = Self.hostKey(host)
        let ids = Array(((seen[key] ?? []) + [id]).suffix(Self.perHostLimit))
        return LeoSurfacedFileLedger(seen: seen.merging([key: ids]) { _, new in new })
    }

    private static func hostKey(_ host: LeoHostID) -> String {
        switch host {
        case .local: "local"
        case .remote(let name): "remote:\(name)"
        }
    }
}

protocol LeoSurfacedFileSeenStore {
    func load() -> LeoSurfacedFileLedger
    func save(_ ledger: LeoSurfacedFileLedger)
}

/// The ledger as JSON under one key. Unreadable data reads as nothing
/// seen: at worst a file badges again.
final class LeoUserDefaultsSurfacedFileSeenStore: LeoSurfacedFileSeenStore {
    static let key = "leo.surfacedFiles.seen"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> LeoSurfacedFileLedger {
        guard let data = defaults.data(forKey: Self.key) else { return LeoSurfacedFileLedger() }
        do {
            return try JSONDecoder().decode(LeoSurfacedFileLedger.self, from: data)
        } catch {
            Self.logger.error("surfaced-file seen ids unreadable: \(error.localizedDescription, privacy: .public)")
            return LeoSurfacedFileLedger()
        }
    }

    func save(_ ledger: LeoSurfacedFileLedger) {
        do {
            defaults.set(try JSONEncoder().encode(ledger), forKey: Self.key)
        } catch {
            Self.logger.error("surfaced-file seen ids not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class LeoInMemorySurfacedFileSeenStore: LeoSurfacedFileSeenStore {
    private var ledger = LeoSurfacedFileLedger()

    init() {}

    func load() -> LeoSurfacedFileLedger { ledger }
    func save(_ ledger: LeoSurfacedFileLedger) { self.ledger = ledger }
}
