import Foundation

struct LeoPollScheduler {
    enum Input: Sendable {
        case sidebarVisibleCountChanged(Int)
        case windowOcclusionChanged(Bool)
        case appHiddenChanged(Bool)
        case sseEvent(LeoObserveEvent)
        case refreshRequested
        case tick
        case refreshStarted
        case refreshFinished
    }

    enum Output: Equatable, Sendable { case refreshNow, scheduleTick(after: TimeInterval), pause, resume }

    private let now: @Sendable () -> Date
    private var visibleCount = 0
    private var occluded = false
    private var appHidden = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var polling = false

    init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    mutating func reset() {
        visibleCount = 0
        occluded = false
        appHidden = false
        refreshInFlight = false
        refreshPending = false
        polling = false
    }

    mutating func reduce(_ input: Input) -> [Output] {
        _ = now()
        switch input {
        case .sidebarVisibleCountChanged(let count): visibleCount = max(0, count)
        case .windowOcclusionChanged(let value): occluded = value
        case .appHiddenChanged(let value): appHidden = value
        case .refreshStarted: refreshInFlight = true; return []
        case .refreshFinished:
            refreshInFlight = false
            guard refreshPending else { return [] }
            refreshPending = false
            return [.refreshNow]
        case .tick:
            guard canPoll else { return [] }
            return requestRefresh() + [.scheduleTick(after: 2)]
        case .refreshRequested:
            return requestRefresh()
        case .sseEvent(let event):
            guard event.requiresRefresh else { return [] }
            return requestRefresh()
        }
        guard canPoll != polling else { return [] }
        polling = canPoll
        return polling ? [.resume] + requestRefresh() + [.scheduleTick(after: 2)] : [.pause]
    }

    private var canPoll: Bool { visibleCount > 0 && !occluded && !appHidden }

    private mutating func requestRefresh() -> [Output] {
        guard !refreshInFlight else { refreshPending = true; return [] }
        return [.refreshNow]
    }
}

private extension LeoObserveEvent {
    var requiresRefresh: Bool {
        switch self {
        case .agentSpawned, .agentStateChanged, .agentStopped, .connected, .gap, .snapshot, .hello: true
        case .agentActivity, .disconnected: false
        }
    }
}
