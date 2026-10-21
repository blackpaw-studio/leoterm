import Foundation

/// Drives the Pair a Device panel: fetches a pairing payload, refreshes it
/// when it expires, and walks the web-disabled → enable → retry path. UI-free;
/// the panel renders `state`. The sleep and the wall clock are injected, so
/// tests never wait.
@MainActor final class LeoPairingModel {
    enum State: Equatable {
        case loading
        /// The shown code expired; a replacement is being fetched.
        case refreshing
        case ready(LeoPairingPayload)
        case webDisabled(message: String?)
        case enablingWeb
        case failed(String)
    }

    /// After `web enable` restarts the daemon, pairing is retried this often...
    nonisolated static let restartRetrySeconds: UInt64 = 1
    /// ...for up to this many retries before the failure is shown.
    nonisolated static let restartRetryAttempts = 10

    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    private(set) var state: State = .loading {
        didSet { if state != oldValue { onChange?(state) } }
    }
    var onChange: ((State) -> Void)?

    private let service: LeoPairingService
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?

    init(
        service: LeoPairingService,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.sleep = sleep
        self.now = now
    }

    /// Fetches a code and keeps it fresh. Also the "Try Again" action.
    func start() {
        state = .loading
        launch { await $0.pairAndRefresh(retries: 0) }
    }

    /// Runs `leo web enable`, then pairs again (waiting out a daemon restart).
    func enableWebAccess() {
        guard case .webDisabled = state else { return }
        state = .enablingWeb
        launch { model in
            do {
                let result = try await model.service.enableWeb()
                await model.pairAndRefresh(retries: result.restarted ? Self.restartRetryAttempts : 0)
            } catch is CancellationError {
            } catch {
                model.state = Self.state(for: error)
            }
        }
    }

    /// Cancels any fetch and the pending refresh.
    func stop() {
        task?.cancel()
        task = nil
    }

    private func launch(_ body: @escaping @MainActor (LeoPairingModel) async -> Void) {
        task?.cancel()
        task = Task { await body(self) }
    }

    private func pairAndRefresh(retries: Int) async {
        var retries = retries
        do {
            while true {
                let payload = try await pairRetrying(attempts: retries)
                try Task.checkCancellation()
                state = .ready(payload)
                retries = 0
                try await sleep(refreshNanoseconds(for: payload))
                // The shown code no longer works: take it off screen while the next one is fetched.
                state = .refreshing
            }
        } catch is CancellationError {
        } catch {
            state = Self.state(for: error)
        }
    }

    /// `web_disabled` is never retried: it is an answer, not a daemon that is still coming up.
    private func pairRetrying(attempts: Int) async throws -> LeoPairingPayload {
        var failures = 0
        while true {
            do {
                let payload = try await service.pair()
                guard payload.expiresAt > now() else { throw LeoPairingError.expired }
                return payload
            } catch {
                if case LeoPairingError.webDisabled = error { throw error }
                if error is CancellationError || failures >= attempts { throw error }
                failures += 1
                try await sleep(Self.restartRetrySeconds * Self.nanosecondsPerSecond)
            }
        }
    }

    /// Until `expires_at`. Payloads are rejected if already expired, so this is positive.
    private func refreshNanoseconds(for payload: LeoPairingPayload) -> UInt64 {
        let remaining = payload.expiresAt.timeIntervalSince(now()).rounded(.up)
        return UInt64(max(remaining, 1)) * Self.nanosecondsPerSecond
    }

    private static func state(for error: Error) -> State {
        if case let LeoPairingError.webDisabled(message) = error { return .webDisabled(message: message) }
        if let error = error as? LeoPairingError { return .failed(error.message) }
        return .failed(error.localizedDescription)
    }
}
