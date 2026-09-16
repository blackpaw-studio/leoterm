import Foundation

enum LeoSidebarConnectionPhase: Sendable {
    case connecting
    case connected(daemon: any LeoDaemonClient, activitySource: LeoSidebarActivitySource)
    case failed(message: String)
}

extension LeoSidebarFeed {
    /// Applies a connection-state update for `(host, generation)` from
    /// `LeoHostSelection`. A `(host, generation)` different from the one
    /// currently tracked is a *switch*: every in-flight SSE/list/state task
    /// for the old connection is cancelled and the snapshot resets before
    /// the new phase is applied, so a stale emission from the old connection
    /// can never reach the new target. The same `(host, generation)`
    /// arriving again (e.g. `.connecting` -> `.connected`) is a phase
    /// *update*, not a switch: rows already fetched for it are kept --
    /// `.failed` just greys them via `.failed` connectivity rather than
    /// clearing them.
    func updateConnection(host: LeoHostID, generation: Int, phase: LeoSidebarConnectionPhase) {
        let isNewConnection = connectionHost != host || connectionGeneration != generation
        if isNewConnection {
            connectionHost = host
            connectionGeneration = generation
            selectedHost = host
            eventTask?.cancel()
            refreshTask?.cancel()
            activityTask?.cancel()
            _ = scheduler.reduce(.refreshCancelled)
            activityByName = [:]
            bufferedActivity = []
            needsState = true
            recovering = false
            awaitingHello = false
            snapshot = .init(rows: [], connectivity: .loading, generation: snapshot.generation + 1)
        }

        switch phase {
        case .connecting:
            selectedHostAvailable = false
            // Pause the scheduler explicitly (not just guard on
            // `selectedHostAvailable` in `tick()`/`refresh()`): a poll tick
            // that lands while connecting would otherwise return without
            // rescheduling `pollTask`, permanently killing periodic polling
            // even after a later `.connected` -- since nothing would ever
            // call `.scheduleTick` again. `.connected` below explicitly
            // resumes (and reschedules) via the same `sidebarVisibleCountChanged`
            // transition.
            process(scheduler.reduce(.sidebarVisibleCountChanged(0)))
            pollTask?.cancel()
            if isNewConnection { emit() }
        case .connected(let daemon, let activitySource):
            self.daemon = daemon
            self.activitySource = activitySource
            selectedHostAvailable = true
            startEventTask()
            // `sidebarVisibleCountChanged` only produces an output on an
            // actual visibility *transition* -- which is exactly what's
            // needed the very first time a connection is established
            // (`setInitialPolling` deliberately didn't trigger one, so the
            // scheduler is still at `visibleCount == 0` here) to kick off
            // periodic ticking. A later switch while already polling is NOT
            // a transition (the scheduler is already at the target count),
            // so it produces no output -- fall back to a direct one-shot
            // `refresh()` for that connection instead. Either way this is
            // exactly one refresh, never both.
            let outputs = scheduler.reduce(.sidebarVisibleCountChanged(pollingRequested ? 1 : 0))
            if outputs.isEmpty {
                refresh()
            } else {
                process(outputs)
            }
        case .failed(let message):
            selectedHostAvailable = false
            snapshot = .init(rows: snapshot.rows, connectivity: .failed(message: message), generation: snapshot.generation + 1)
            refreshTask?.cancel()
            activityTask?.cancel()
            _ = scheduler.reduce(.refreshCancelled)
            process(scheduler.reduce(.sidebarVisibleCountChanged(0)))
            pollTask?.cancel()
            emit()
        }
    }
}
