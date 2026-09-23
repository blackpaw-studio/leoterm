#if DEBUG
import Foundation

/// DEBUG builds only: holds every editor save for the seconds named by
/// `LEO_SLOW_SAVE_SECONDS`, so a close or quit waiting on a save that
/// hasn't come back -- its "Closing…" notice, its Quit Anyway banner -- can
/// be seen and screenshotted without a hung remote host. A save whose
/// access is closed meanwhile (left anyway) fails instead of writing.
enum LeoSlowSaveFixture {
    static let environmentKey = "LEO_SLOW_SAVE_SECONDS"

    static func delay(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration? {
        guard let value = environment[environmentKey], let seconds = Double(value), seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    static func wrap(_ access: any LeoFileAccess, delay: Duration) -> any LeoFileAccess {
        SlowSaves(base: access, delay: delay)
    }

    private final class SlowSaves: LeoFileAccess, @unchecked Sendable {
        private let base: any LeoFileAccess
        private let delay: Duration
        private let lock = NSLock()
        private var isClosed = false
        /// Holds in progress, cut short by `close`.
        private var holds: [UUID: Task<Void, Never>] = [:]

        init(base: any LeoFileAccess, delay: Duration) {
            self.base = base
            self.delay = delay
        }

        func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
        func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
        func homeDirectory() async throws -> String { try await base.homeDirectory() }
        func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }

        /// Holds for `delay` (or until closed), then writes unless closed
        /// meanwhile: a save left anyway never lands.
        func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
            let id = UUID()
            let delay = delay
            let hold: Task<Void, Never>? = lock.withLock {
                guard !isClosed else { return nil }
                let hold = Task { _ = try? await Task.sleep(for: delay) }
                holds[id] = hold
                return hold
            }
            await hold?.value
            let isAbandoned = lock.withLock {
                holds[id] = nil
                return isClosed
            }
            guard !isAbandoned else { throw LeoFileAccessError.unavailable(reason: "the save was abandoned") }
            return try await base.write(data, to: path, expecting: expected)
        }

        func close() async {
            let cut = lock.withLock {
                isClosed = true
                defer { holds = [:] }
                return Array(holds.values)
            }
            cut.forEach { $0.cancel() }
            await base.close()
        }
    }
}
#endif
