import Foundation

/// Turns a stream of per-agent usage changes into at most one event per agent
/// per `interval`: the first change fires at once, and the changes that follow
/// inside the window collapse into one trailing fire when it ends. A trailing
/// fire opens a new window, so the rate holds however fast changes arrive.
///
/// The clock and the scheduler are injected, so tests step time by hand.
@MainActor public final class LeoPluginUsageCoalescer {
    public static let defaultInterval: TimeInterval = 1

    private struct Window {
        var lastFire: TimeInterval
        var pending: (token: UUID, handle: any LeoPluginTimerHandle)?
    }

    private let interval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let scheduler: any LeoPluginTimerScheduling
    private let fire: @MainActor (LeoPluginAgentRef) -> Void
    private var windows: [LeoPluginAgentRef: Window] = [:]

    /// - Parameters:
    ///   - now: monotonic seconds.
    ///   - fire: called on the main actor, once per coalesced change.
    public init(
        interval: TimeInterval = defaultInterval, now: @escaping @Sendable () -> TimeInterval,
        scheduler: any LeoPluginTimerScheduling, fire: @escaping @MainActor (LeoPluginAgentRef) -> Void
    ) {
        self.interval = interval
        self.now = now
        self.scheduler = scheduler
        self.fire = fire
    }

    /// Records that `agent`'s usage changed.
    public func change(_ agent: LeoPluginAgentRef) {
        let current = now()
        guard var window = windows[agent] else {
            windows[agent] = Window(lastFire: current)
            fire(agent)
            return
        }
        // A trailing fire is already coming; this change rides on it.
        if window.pending != nil { return }
        let remaining = interval - (current - window.lastFire)
        guard remaining > 0 else {
            window.lastFire = current
            windows[agent] = window
            fire(agent)
            return
        }
        let token = UUID()
        let handle = scheduler.schedule(after: remaining, repeating: false) { [weak self] in
            Task { @MainActor in self?.trailingFire(agent, token: token) }
        }
        window.pending = (token, handle)
        windows[agent] = window
    }

    /// Forgets every window and drops pending fires (the manager stopped).
    public func cancelAll() {
        for window in windows.values { window.pending?.handle.cancel() }
        windows = [:]
    }

    private func trailingFire(_ agent: LeoPluginAgentRef, token: UUID) {
        guard var window = windows[agent], window.pending?.token == token else { return }
        window.pending = nil
        window.lastFire = now()
        windows[agent] = window
        fire(agent)
    }
}
