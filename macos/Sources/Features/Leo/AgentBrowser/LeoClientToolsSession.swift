import Foundation
import LeoKit
import OSLog

/// The daemon's client-tools routes, as one machine's session uses them.
/// `LeoClientToolsClient` conforms; tests conform with a fake.
protocol LeoClientToolsProviding: AnyObject, Sendable {
    func events() async -> AsyncStream<LeoClientToolsEvent>
    func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int
    func claim(_ requestID: String) async throws -> LeoClientToolRequest
    func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws
    func pending() async throws -> [LeoClientToolPending]
}

extension LeoClientToolsClient: LeoClientToolsProviding {}

/// Runs a client-tools request for an agent on a machine. The app's agent
/// browsers (`LeoAgentBrowsers`) run every claimed `browser` request.
@MainActor protocol LeoClientToolsExecuting: AnyObject {
    func execute(_ request: LeoClientToolRequest, on host: LeoHostID) async -> LeoClientToolOutcome
}

/// One machine's client-tools provider stream (C6). While the machine is
/// connected, its daemon advertises `client_tools`, this Mac can run the
/// browser (macOS 14) and the Settings toggle is on, the session holds a
/// stream open, reopening it with backoff when it drops. On every hello it
/// registers the `browser` group and recovers pending requests; it claims
/// each request, runs it and posts the result.
///
/// A request runs once however often it is seen: a running request whose
/// stream dropped is re-claimed on the next stream, not rerun, and its
/// result goes back once the claim is held again. A `cancelled` event, the
/// session stopping or the setting turning off aborts what runs, unanswered.
@MainActor final class LeoClientToolsSession {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "ClientTools")
    private static let maximumBackoff = 30

    private enum Claim {
        /// Not held: never claimed, or claimed on a stream that has gone.
        case released
        case claiming
        /// Held, claimed on the stream with this generation.
        case held(generation: Int)
    }

    private struct InFlight {
        var claim = Claim.released
        var run: Task<Void, Never>?
        /// Set when the run finished before its result could be posted.
        var outcome: LeoClientToolOutcome?
    }

    private let host: LeoHostID
    private let client: any LeoClientToolsProviding
    private let executor: any LeoClientToolsExecuting
    private let isPlatformSupported: Bool
    private let sleep: Sleep

    private var isStarted = false
    private var isAdvertised = false
    private var isEnabled = true
    /// The daemon answered that it has no client tools: no retry until the
    /// session starts again or the daemon advertises the feature anew.
    private var isUnsupported = false
    private var streamTask: Task<Void, Never>?
    private var generation = 0
    /// The generation of the open stream once it said hello.
    private var liveGeneration: Int?
    private var inFlight: [String: InFlight] = [:]
    /// Requests another client holds or the daemon settled, on this stream.
    private var refused: Set<String> = []

    init(
        host: LeoHostID, client: any LeoClientToolsProviding, executor: any LeoClientToolsExecuting,
        isPlatformSupported: Bool, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.host = host
        self.client = client
        self.executor = executor
        self.isPlatformSupported = isPlatformSupported
        self.sleep = sleep
    }

    // MARK: - Lifecycle

    /// The machine connected.
    func start() {
        isStarted = true
        isUnsupported = false
        reconcile()
    }

    /// The machine is no longer connected (or the app is quitting).
    func stop() {
        isStarted = false
        reconcile()
    }

    /// Whether the daemon advertises `client_tools`.
    func setAdvertised(_ advertised: Bool) {
        if advertised, !isAdvertised { isUnsupported = false }
        isAdvertised = advertised
        reconcile()
    }

    /// The "Agent browser" setting.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        reconcile()
    }

    private var shouldRun: Bool {
        isStarted && isAdvertised && isEnabled && isPlatformSupported && !isUnsupported
    }

    private func reconcile() {
        if shouldRun, streamTask == nil {
            streamTask = Task { [weak self] in await self?.runStreams() }
        } else if !shouldRun, let task = streamTask {
            task.cancel()
            streamTask = nil
            liveGeneration = nil
            abortAll()
        }
    }

    // MARK: - Stream

    private func runStreams() async {
        var failures = 0
        while !Task.isCancelled {
            generation += 1
            let current = generation
            var reason: String?
            for await event in await client.events() {
                if case .disconnected(let why) = event { reason = why; continue }
                if case .hello = event { failures = 0 }
                receive(event, on: current)
            }
            if liveGeneration == current { liveGeneration = nil }
            guard !Task.isCancelled else { return }
            if reason == LeoClientToolsClient.unsupportedReason {
                Self.logger.log("clientTools: daemon has no client tools host=\(String(describing: self.host), privacy: .public)")
                isUnsupported = true
                streamTask = nil
                return
            }
            failures += 1
            do { try await sleep(.seconds(Self.backoff(after: failures))) } catch { return }
        }
    }

    private static func backoff(after failures: Int) -> Int {
        min(1 << min(failures - 1, 5), maximumBackoff)
    }

    private func receive(_ event: LeoClientToolsEvent, on stream: Int) {
        switch event {
        case .hello:
            liveGeneration = stream
            refused = []
            Task { await self.registerAndRecover(on: stream) }
        case .request(let request):
            guard liveGeneration == stream else { return }
            consider(request, claimedBy: "", on: stream)
        case .cancelled(let cancellation):
            abort(cancellation.id)
        case .gap:
            Task { await self.recover(on: stream) }
        case .changed, .disconnected:
            break
        }
    }

    private func registerAndRecover(on stream: Int) async {
        do {
            _ = try await client.register(group: LeoBrowserTools.group, tools: LeoBrowserTools.definitions)
        } catch {
            Self.logger.error("clientTools: register failed error=\(String(describing: error), privacy: .public)")
        }
        await recover(on: stream)
    }

    /// Reconciles with the daemon's pending list: aborts what it no longer
    /// has, claims what nobody holds, re-claims what this Mac still runs.
    private func recover(on stream: Int) async {
        let known = Set(inFlight.keys)
        let listed: [LeoClientToolPending]
        do {
            listed = try await client.pending()
        } catch {
            Self.logger.error("clientTools: pending failed error=\(String(describing: error), privacy: .public)")
            return
        }
        guard liveGeneration == stream else { return }
        known.subtracting(listed.map(\.request.id)).forEach(abort)
        for pending in listed {
            consider(pending.request, claimedBy: pending.claimedBy, on: stream)
        }
    }

    // MARK: - Requests

    private func consider(_ request: LeoClientToolRequest, claimedBy: String, on stream: Int) {
        guard request.group == LeoBrowserTools.group, claimedBy.isEmpty else { return }
        switch inFlight[request.id]?.claim {
        case .claiming: return
        case .held(let generation) where generation == stream: return
        case nil where refused.contains(request.id): return
        default: claim(request.id, on: stream)
        }
    }

    private func claim(_ id: String, on stream: Int) {
        inFlight[id, default: InFlight()].claim = .claiming
        Task {
            do {
                claimed(try await client.claim(id), on: stream)
            } catch {
                claimFailed(id, error)
            }
        }
    }

    private func claimed(_ request: LeoClientToolRequest, on stream: Int) {
        let id = request.id
        guard let entry = inFlight[id] else { return }
        guard liveGeneration == stream else {
            inFlight[id]?.claim = .released
            return
        }
        inFlight[id]?.claim = .held(generation: stream)
        if entry.run == nil {
            inFlight[id]?.run = Task {
                let outcome = await executor.execute(request, on: host)
                finished(id, outcome)
            }
        }
        if let outcome = entry.outcome { post(id, outcome, on: stream) }
    }

    private func claimFailed(_ id: String, _ error: any Error) {
        guard let entry = inFlight[id] else { return }
        Self.logger.log("clientTools: claim failed id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
        let isTaken = Self.isTaken(error)
        if entry.run == nil {
            inFlight[id] = nil
            if isTaken { refused.insert(id) }
        } else if isTaken {
            abort(id)
        } else {
            inFlight[id]?.claim = .released
        }
    }

    private func finished(_ id: String, _ outcome: LeoClientToolOutcome) {
        guard inFlight[id] != nil else { return }
        inFlight[id]?.outcome = outcome
        guard case .held(let stream) = inFlight[id]?.claim, stream == liveGeneration else { return }
        post(id, outcome, on: stream)
    }

    /// Posts `outcome`, and after a transient failure posts it again with
    /// the stream's backoff while the claim is still held on `stream` (the
    /// daemon still has this Mac as the claimant). Once that stream drops,
    /// the request's re-claim on the next one posts it instead.
    private func post(_ id: String, _ outcome: LeoClientToolOutcome, on stream: Int) {
        Task {
            var failures = 0
            while true {
                do {
                    try await client.postResult(id, outcome)
                    inFlight[id] = nil
                    return
                } catch {
                    Self.logger.error("clientTools: result failed id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    if Self.isTaken(error) {
                        inFlight[id] = nil
                        return
                    }
                }
                failures += 1
                do { try await sleep(.seconds(Self.backoff(after: failures))) } catch { return }
                guard liveGeneration == stream, case .held(stream) = inFlight[id]?.claim else { return }
            }
        }
    }

    private func abort(_ id: String) {
        inFlight.removeValue(forKey: id)?.run?.cancel()
    }

    private func abortAll() {
        let aborted = inFlight
        inFlight = [:]
        refused = []
        aborted.values.forEach { $0.run?.cancel() }
    }

    /// The daemon says the request is someone else's or no longer open.
    private static func isTaken(_ error: any Error) -> Bool {
        switch error as? LeoClientToolsError {
        case .alreadyClaimed, .ownedByOther, .unknownRequest, .notClaimant, .alreadySettled: true
        default: false
        }
    }
}
