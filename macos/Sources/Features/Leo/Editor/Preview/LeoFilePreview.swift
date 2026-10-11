import Combine
import Foundation

/// What the pane shows for a previewed file (B-278) while its bytes are
/// fetched into `LeoFilePreviewCache`, and the fetch that gets them. Each
/// fetch has a generation: one superseded by a newer fetch (or by `close`)
/// throws its result away, folder and all, so a stale fetch landing late
/// never replaces a newer one. A refetch keeps the old file on screen
/// until the new one lands; only then is the old folder deleted. State
/// changes publish synchronously, so a view has let go of a file (closed
/// its Quick Look view, swapped its player item) before its folder goes.
@MainActor final class LeoFilePreview: ObservableObject {
    enum State: Equatable {
        /// `fraction` of the file fetched so far, once known.
        case loading(fraction: Double?)
        case ready(URL)
        /// Binary by sniff, or over the fetch limit.
        case unsupported(typeName: String)
        case failed(String)
        /// The document closed: nothing is shown any more.
        case closed
    }

    typealias Fetch = @Sendable (_ progress: @escaping @Sendable (UInt64) async throws -> Void) async throws -> LeoFilePreviewFetch

    /// Progress publishes in steps at least this big.
    static let progressStep = 0.01

    @Published private(set) var state: State
    let typeName: String
    private let fetch: Fetch?
    private let discard: @Sendable (LeoFilePreviewFetch) -> Void
    private var generation = 0
    private var task: Task<Void, Never>?
    /// The fetch whose file `state` shows.
    private var shown: LeoFilePreviewFetch?

    /// A file that can't be previewed: nothing to fetch.
    init(unsupported typeName: String) {
        self.typeName = typeName
        state = .unsupported(typeName: typeName)
        fetch = nil
        discard = { _ in }
    }

    init(typeName: String, fetch: @escaping Fetch, discard: @escaping @Sendable (LeoFilePreviewFetch) -> Void) {
        self.typeName = typeName
        state = .loading(fraction: nil)
        self.fetch = fetch
        self.discard = discard
    }

    /// Whether this preview streams its file (as opposed to a fixed state).
    var isFetched: Bool { fetch != nil }

    /// Fetches the file (again), superseding any fetch in flight. `size`
    /// scales the progress; `onFetched` gets the `stat` the bytes were
    /// read at, once they land.
    func refresh(size: UInt64, onFetched: @escaping @MainActor (LeoFileStat) -> Void) {
        guard let fetch, state != .closed else { return }
        generation += 1
        let generation = generation
        task?.cancel()
        let discard = discard
        let progress: @Sendable (UInt64) async throws -> Void = { [weak self] offset in
            await self?.progressed(offset, of: size, generation: generation)
        }
        task = Task { [weak self] in
            let result: Result<LeoFilePreviewFetch, Error>
            do {
                result = .success(try await fetch(progress))
            } catch {
                result = .failure(error)
            }
            guard let self else {
                if case .success(let fetched) = result { discard(fetched) }
                return
            }
            self.land(result, generation: generation, onFetched: onFetched)
        }
    }

    /// Stops the fetch in flight, if any; its result is thrown away.
    func cancel() {
        generation += 1
        task?.cancel()
    }

    /// Waits for the fetch in flight (tests, and anything that must see
    /// its outcome).
    func settle() async {
        await task?.value
    }

    /// Cancels any fetch, waits for it to stop, then lets go of the file
    /// shown (`.closed`) and deletes its folder. Final.
    func close() async {
        cancel()
        await task?.value
        task = nil
        state = .closed
        if let shown { discard(shown) }
        shown = nil
    }

    // MARK: - Helpers

    private func progressed(_ offset: UInt64, of size: UInt64, generation: Int) {
        guard generation == self.generation, size > 0, case .loading(let old) = state else { return }
        let fraction = min(1, Double(offset) / Double(size))
        guard fraction - (old ?? 0) >= Self.progressStep || (old == nil && fraction > 0) else { return }
        state = .loading(fraction: fraction)
    }

    private func land(_ result: Result<LeoFilePreviewFetch, Error>, generation: Int, onFetched: @MainActor (LeoFileStat) -> Void) {
        guard generation == self.generation, state != .closed else {
            if case .success(let fetched) = result { discard(fetched) }
            return
        }
        task = nil
        let previous = shown
        switch result {
        case .success(let fetched):
            shown = fetched
            state = .ready(fetched.file)
            onFetched(fetched.stat)
        case .failure(let error):
            shown = nil
            state = Self.state(for: error, typeName: typeName)
        }
        if let previous { discard(previous) }
    }

    private static func state(for error: Error, typeName: String) -> State {
        if case LeoFileAccessError.tooLarge = error { return .unsupported(typeName: typeName) }
        return .failed(LeoFileExport.message(for: error))
    }
}
