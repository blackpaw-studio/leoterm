import AppKit
import Combine
import os

/// App-owned model backing the Leo sidebar: holds the active host's agent store,
/// the sidebar's visibility, and a poll timer that runs only while the sidebar
/// is visible (the daemon has no event stream, so the roster is polled).
///
/// There is exactly one sidebar; it **retargets** to follow the active board's
/// host via `setActiveHost(_:)`, acquiring the host's store from the shared
/// `LeoHostRegistry` and releasing the previous one.
@MainActor
final class LeoSidebarModel: ObservableObject {
    @Published var isVisible: Bool = false
    /// The store for the currently-active host. Starts as a localhost placeholder
    /// (not registry-acquired) so the view always has something to bind to.
    @Published private(set) var store: LeoAgentStore
    /// Non-nil when the last retarget failed (e.g. a remote forward was
    /// unreachable); cleared on the next successful switch.
    @Published private(set) var activationError: String?

    /// The host the sidebar is currently showing. Defaults to localhost.
    @Published private(set) var activeHost: String = LeoHost.localhostName

    /// The hosts available to pick from. Always contains a localhost entry so the
    /// picker works even when `leo host list` is unavailable (old binary).
    @Published private(set) var hosts: [LeoHost] = [
        LeoHost(name: LeoHost.localhostName, ssh: nil, isDefault: false, isLocal: true)
    ]

    private let registry: LeoHostRegistry
    private let catalog: LeoHostCatalog
    /// The host currently held via the registry, or `nil` for the initial
    /// localhost placeholder (which was NOT registry-acquired and must not be
    /// released).
    private var acquiredHost: String?
    /// Monotonic token bumped on every `setActiveHost` entry. Captured before the
    /// `await` and re-checked after so a slow acquire that resumes behind a newer
    /// retarget can detect it lost the race and back out cleanly.
    private var hostGeneration: UInt64 = 0
    /// The host that was most recently attempted but failed to acquire. Stored so
    /// `retryActivation()` can re-attempt the exact same target without the caller
    /// needing to remember it.
    private var lastFailedRetargetHost: String?
    /// A host whose forward died and that we should re-acquire on the next
    /// poll tick. Cleared once any activation succeeds.
    private var staleHost: String?
    /// Number of `activate` calls currently suspended in `registry.store`. The
    /// poll loop must not start a healing retarget while a user-driven one is
    /// in flight, or it would supersede the user's choice.
    private var activationsInFlight = 0
    /// True while `pollTick` is running, so an activation triggered from inside
    /// the tick doesn't restart the very loop it is running on.
    private var isInPollTick = false
    private var pollTask: Task<Void, Never>?
    /// How often the roster is polled while the sidebar is visible. Injectable
    /// so tests can drive the poll loop without real-time waits.
    private let pollInterval: Duration
    static let defaultPollInterval: Duration = .seconds(3)
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-sidebar")

    /// The synthesized localhost entry that is always present, even when
    /// `leo host list` can't be reached (e.g. an old leo binary).
    private static let localhostEntry = LeoHost(
        name: LeoHost.localhostName, ssh: nil, isDefault: false, isLocal: true)

    init(
        registry: LeoHostRegistry,
        catalog: LeoHostCatalog = LeoHostCatalog(),
        store: LeoAgentStore? = nil,
        pollInterval: Duration = LeoSidebarModel.defaultPollInterval
    ) {
        self.registry = registry
        self.catalog = catalog
        self.store = store ?? LeoAgentStore()
        self.pollInterval = pollInterval
    }

    /// Refresh the available host list via `leo host list --json`. On any failure
    /// (notably an old leo binary that lacks `host list`) the existing list is
    /// kept and we ensure a localhost entry remains, so the picker never breaks.
    func refreshHosts() async {
        do {
            let fetched = try await catalog.listHosts()
            hosts = fetched.contains(where: { $0.isLocal }) ? fetched : [Self.localhostEntry] + fetched
        } catch {
            Self.logger.warning(
                "host list unavailable, keeping localhost-only: \(error.errorDescription ?? "?", privacy: .public)")
            if !hosts.contains(where: { $0.name == LeoHost.localhostName }) {
                hosts = [Self.localhostEntry]
            }
        }
    }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { startPolling() } else { stopPolling() }
    }

    /// Retarget the sidebar to `host`. Acquires the host's store from the
    /// registry, releasing the previously-acquired host. A no-op when already on
    /// `host` (so switching between two tabs on the same host causes no churn).
    /// On failure the current store/host are left unchanged and `activationError`
    /// is set.
    ///
    /// Returns the resolved store on success, or `nil` on failure or when a newer
    /// retarget superseded this one mid-acquire. Callers that reconcile against the
    /// activated host must use the returned store rather than re-reading `store`,
    /// which may have moved on.
    @discardableResult
    func setActiveHost(_ host: String) async -> LeoAgentStore? {
        // Bump on EVERY entry, including the same-host no-op: an A -> B -> A
        // sequence must invalidate B's in-flight acquire, otherwise B lands last
        // and the sidebar ends up on the host the user just navigated away from.
        hostGeneration &+= 1
        let generation = hostGeneration
        guard host != activeHost else { return store }
        return await activate(host, generation: generation)
    }

    /// Re-acquire `host` even when it is already the active host. Used to
    /// rebuild a connection whose forward died underneath us.
    @discardableResult
    private func reactivate(_ host: String) async -> LeoAgentStore? {
        hostGeneration &+= 1
        return await activate(host, generation: hostGeneration)
    }

    /// Acquire `host` from the registry and adopt it as active, unless a newer
    /// retarget (a higher `hostGeneration`) superseded this one mid-acquire.
    private func activate(_ host: String, generation: UInt64) async -> LeoAgentStore? {
        activationsInFlight += 1
        defer { activationsInFlight -= 1 }
        do {
            let newStore = try await registry.store(for: host)
            // A newer retarget won the race: release the hold we just acquired so
            // the refcount doesn't leak, and leave the active state untouched.
            guard generation == hostGeneration else {
                registry.release(host)
                return nil
            }
            if let acquiredHost { registry.release(acquiredHost) }
            acquiredHost = host
            activeHost = host
            store = newStore
            activationError = nil
            lastFailedRetargetHost = nil
            staleHost = nil
            // Restarting the poll loop from inside a poll tick would double the
            // refresh for that tick; the running loop already picks up the new
            // store on its next iteration.
            if isVisible, !isInPollTick { startPolling() }
            return newStore
        } catch is CancellationError {
            // Our own task was cancelled (teardown, a superseding retarget):
            // no hold was claimed and there is nothing to report.
            return nil
        } catch {
            // A newer retarget superseded this failed attempt: don't surface its
            // error over the newer one's state.
            guard generation == hostGeneration else { return nil }
            // The registry already cleaned up the failed acquire, so release
            // nothing here.
            let message = (error as? LeoError)?.errorDescription ?? error.localizedDescription
            Self.logger.warning(
                "failed to activate host \(host, privacy: .public): \(message, privacy: .public)")
            activationError = message
            lastFailedRetargetHost = host
            return nil
        }
    }

    /// Re-attempt the last failed host retarget. No-op if no retarget has failed.
    /// Uses the forced path so a retry works even when the failed host is
    /// already the nominally-active one (e.g. its forward died).
    func retryActivation() async {
        guard let host = lastFailedRetargetHost else { return }
        await reactivate(host)
    }

    /// Dismiss the current error banner — clears both the retarget error and any
    /// store-level daemon error without triggering a new refresh.
    func dismissError() {
        activationError = nil
        lastFailedRetargetHost = nil
        store.clearLastError()
    }

    /// Release any registry-held host. Call before the model is discarded.
    /// Idempotent: a second call releases nothing.
    func teardown() {
        stopPolling()
        staleHost = nil
        // Invalidate any activation still in flight: it will see a newer
        // generation, release the hold it acquired, and touch nothing else.
        hostGeneration &+= 1
        guard let acquiredHost else { return }
        registry.release(acquiredHost)
        self.acquiredHost = nil
    }

    deinit {
        // `Task.cancel()` is safe to call from any isolation, including `deinit`.
        // Nothing else happens here: `deinit` is nonisolated and can run off the
        // main actor, so touching the MainActor-isolated registry (even via
        // `assumeIsolated`) would trap. Owners must call `teardown()`.
        pollTask?.cancel()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollTick()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    /// One poll iteration: first heal a host whose forward died (the registry
    /// drops the connection, so `hasConnection` goes false), then refresh the
    /// roster from whichever store is active afterwards.
    private func pollTick() async {
        isInPollTick = true
        defer { isInPollTick = false }
        if let acquiredHost, !registry.hasConnection(acquiredHost) {
            staleHost = acquiredHost
            // Still release: the registry keeps an orphan slot for the holds
            // outstanding against the dead connection, and leaving ours
            // unclaimed would make a later legitimate release get absorbed by
            // that slot instead of tearing the replacement down.
            registry.release(acquiredHost)
            self.acquiredHost = nil
        }
        // Only heal the host we are actually showing, and never while a
        // user-driven retarget is in flight — healing bumps `hostGeneration`
        // and would otherwise supersede the user's choice.
        if let staleHost {
            if staleHost != activeHost {
                self.staleHost = nil
            } else if activationsInFlight == 0 {
                await reactivate(staleHost)
            }
        }
        await store.refresh()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
