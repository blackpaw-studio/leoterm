import Foundation

/// Drives sidebar list refreshes. While the SSE `/events` stream is
/// connected, list refreshes are pushed by SSE state events (coalesced
/// within `sseCoalesceInterval`); no periodic poll runs. While SSE is
/// disconnected or reconnecting, this falls back to periodic polling at
/// `disconnectedPollInterval`, plus an immediate refresh the moment SSE
/// reconnects. The same poll also runs while an attention baseline is
/// pending with SSE connected -- even with the sidebar hidden, when
/// notifications matter most.
struct LeoPollScheduler {
    enum Input: Sendable {
        case sidebarVisibleCountChanged(Int)
        case windowOcclusionChanged(Bool)
        case appHiddenChanged(Bool)
        case sseEvent(LeoObserveEvent)
        case refreshRequested
        case tick
        case sseRefreshDue
        case refreshStarted
        case refreshFinished
        case refreshCancelled
        /// Whether an attention `/state` baseline is still pending.
        case baselinePendingChanged(Bool)
    }

    enum Output: Equatable, Sendable {
        case refreshNow
        case scheduleTick(after: TimeInterval)
        case scheduleSSERefresh(after: TimeInterval)
        case pause
        case resume
    }

    /// Fallback poll cadence used only while the SSE stream is disconnected.
    private static let disconnectedPollInterval: TimeInterval = 30
    /// Coalescing window for bursts of SSE state events (spawn/state/stop).
    private static let sseCoalesceInterval: TimeInterval = 0.1

    private let now: @Sendable () -> Date
    private var visibleCount = 0
    private var occluded = false
    private var appHidden = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var polling = false
    private var sseConnected = false
    private var pendingSSERefresh = false
    private var baselinePending = false

    init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// Clears SSE-connectivity tracking (`sseConnected`/`pendingSSERefresh`)
    /// without touching visibility/in-flight bookkeeping -- used when a
    /// connection switch (`LeoSidebarFeedTarget.updateConnection`) replaces
    /// the SSE stream this scheduler was tracking. Without this, a switch
    /// away from a connection whose SSE was connected would leave
    /// `sseConnected` stuck `true`, making the new connection's own
    /// `shouldPoll` computation stay `false` until ITS SSE happened to
    /// report `.connected`/`.disconnected` -- so the 30s fallback poll would
    /// never start for it in the meantime.
    mutating func resetConnectionTracking() {
        sseConnected = false
        pendingSSERefresh = false
    }

    mutating func reset() {
        visibleCount = 0
        occluded = false
        appHidden = false
        refreshInFlight = false
        refreshPending = false
        polling = false
        sseConnected = false
        pendingSSERefresh = false
        baselinePending = false
    }

    mutating func reduce(_ input: Input) -> [Output] {
        _ = now()
        switch input {
        case .sidebarVisibleCountChanged(let count):
            visibleCount = max(0, count)
            return applyPollingTransition(refreshOnResume: true)
        case .windowOcclusionChanged(let value):
            occluded = value
            return applyPollingTransition(refreshOnResume: true)
        case .appHiddenChanged(let value):
            appHidden = value
            return applyPollingTransition(refreshOnResume: true)
        case .refreshStarted:
            refreshInFlight = true
            return []
        case .refreshCancelled:
            refreshInFlight = false
            refreshPending = false
            return []
        case .refreshFinished:
            refreshInFlight = false
            guard refreshPending else { return [] }
            refreshPending = false
            return [.refreshNow]
        case .tick:
            guard shouldPoll else { return [] }
            return requestRefresh() + [.scheduleTick(after: Self.disconnectedPollInterval)]
        case .refreshRequested:
            return requestRefresh()
        case .sseEvent(let event):
            return handle(event)
        case .sseRefreshDue:
            pendingSSERefresh = false
            return requestRefresh()
        case .baselinePendingChanged(let value):
            baselinePending = value
            return applyPollingTransition(refreshOnResume: false)
        }
    }

    /// True whenever the sidebar/palette is visible and not occluded --
    /// independent of SSE connectivity.
    private var visible: Bool { visibleCount > 0 && !occluded && !appHidden }

    /// True when the periodic-poll fallback should be active: visible, and
    /// SSE isn't already delivering live updates -- or SSE is connected with
    /// a baseline still pending (visible or not), so a failed or stale fetch
    /// gets retried by the ordinary poll and notifications resume. A hidden
    /// sidebar never polls a disconnected daemon.
    private var shouldPoll: Bool {
        visible ? !sseConnected || baselinePending : sseConnected && baselinePending
    }

    private mutating func handle(_ event: LeoObserveEvent) -> [Output] {
        switch event {
        case .connected:
            sseConnected = true
            pendingSSERefresh = false
            return applyPollingTransition(refreshOnResume: false) + requestRefresh()
        case .disconnected:
            sseConnected = false
            pendingSSERefresh = false
            return applyPollingTransition(refreshOnResume: false)
        case .hello, .gap, .snapshot:
            // Recovery signals: refresh immediately rather than coalescing,
            // since these are already rare and time-sensitive.
            pendingSSERefresh = false
            return requestRefresh()
        case .agentSpawned, .agentStateChanged, .agentStopped:
            guard !pendingSSERefresh else { return [] }
            pendingSSERefresh = true
            return [.scheduleSSERefresh(after: Self.sseCoalesceInterval)]
        case .agentActivity, .fileSurfaced, .dispatchChanged, .dispatchRemoved, .agentTurnCompleted, .agentUsage, .agentCompaction, .other:
            return []
        }
    }

    /// Turns the periodic-poll fallback on or off in response to a change in
    /// `shouldPoll`. `refreshOnResume` controls whether resuming also fires
    /// an immediate refresh -- true for visibility changes (existing
    /// refresh-on-visible behavior), false for connectivity changes, where
    /// the caller decides separately whether an immediate refresh is due.
    private mutating func applyPollingTransition(refreshOnResume: Bool) -> [Output] {
        let poll = shouldPoll
        guard poll != polling else { return [] }
        polling = poll
        guard polling else { return [.pause] }
        let refresh = refreshOnResume ? requestRefresh() : []
        return [.resume] + refresh + [.scheduleTick(after: Self.disconnectedPollInterval)]
    }

    private mutating func requestRefresh() -> [Output] {
        guard !refreshInFlight else { refreshPending = true; return [] }
        return [.refreshNow]
    }
}
