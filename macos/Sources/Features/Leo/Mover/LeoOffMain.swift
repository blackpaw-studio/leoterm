import Foundation

/// Blocking file-system work (copying a bundle off a slow volume or DMG)
/// must never run on the main thread: the app would freeze mid-move. An
/// explicit queue rather than an isolation rule, so it stays off the main
/// thread whatever the caller's executor is.
enum LeoOffMain {
    private static let queue = DispatchQueue(label: "studio.blackpaw.leo.mover", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
