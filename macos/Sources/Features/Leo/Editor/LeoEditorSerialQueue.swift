/// Runs async main-actor operations one at a time, in call order. The
/// editor's disk operations must not interleave at their suspension points:
/// a focus check landing mid-save would see the saved file's new version
/// before the save records it, and flag the user's own save as an external
/// change.
@MainActor final class LeoEditorSerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    func runThrowing<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await run { () async -> Result<T, Error> in
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }.get()
    }

    /// Waits for everything queued so far.
    func drain() async {
        await tail?.value
    }
}
