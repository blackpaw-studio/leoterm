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
    private(set) var activeHost: String = LeoHost.localhostName

    private let registry: LeoHostRegistry
    /// The host currently held via the registry, or `nil` for the initial
    /// localhost placeholder (which was NOT registry-acquired and must not be
    /// released).
    private var acquiredHost: String?
    /// Monotonic token bumped on every `setActiveHost` entry. Captured before the
    /// `await` and re-checked after so a slow acquire that resumes behind a newer
    /// retarget can detect it lost the race and back out cleanly.
    private var hostGeneration: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-sidebar")

    init(registry: LeoHostRegistry, store: LeoAgentStore? = nil) {
        self.registry = registry
        self.store = store ?? LeoAgentStore()
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
        guard host != activeHost else { return store }
        // Capture a generation token before suspending. The post-`await` body runs
        // synchronously on the MainActor, so re-checking the token there reliably
        // detects whether a newer retarget interleaved while we were suspended.
        hostGeneration &+= 1
        let generation = hostGeneration
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
            if isVisible { startPolling() }
            return newStore
        } catch {
            // A newer retarget superseded this failed attempt: don't surface its
            // error over the newer one's state.
            guard generation == hostGeneration else { return nil }
            // `registry.store(for:)` throws `LeoError`; the registry already
            // cleaned up the failed acquire, so release nothing here.
            Self.logger.warning(
                "failed to activate host \(host, privacy: .public): \(error.errorDescription ?? "?", privacy: .public)")
            activationError = error.errorDescription
            return nil
        }
    }

    /// Release any registry-held host. Call before the model is discarded.
    func teardown() {
        stopPolling()
        if let acquiredHost {
            registry.release(acquiredHost)
            self.acquiredHost = nil
        }
    }

    deinit {
        // `Task.cancel()` is safe to call from any isolation, including `deinit`.
        pollTask?.cancel()
        // `release` is MainActor-isolated and sync. A `@MainActor` class is torn
        // down on the main actor, so assuming isolation here is safe and lets the
        // model clean up its forward even if `teardown()` was never called.
        guard let acquiredHost else { return }
        MainActor.assumeIsolated { registry.release(acquiredHost) }
    }

    private func startPolling() {
        pollTask?.cancel()
        let target = store
        pollTask = Task {
            while !Task.isCancelled {
                await target.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
