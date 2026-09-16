import Foundation

extension LeoSidebarFeed {
    func select(_ host: LeoHostID) {
        guard host != selectedHost else { return }
        selectedHost = host
        selectedHostAvailable = true
        snapshot = .init(rows: [], connectivity: .loading, generation: snapshot.generation + 1)
        activityByName = [:]
        needsState = true
        refreshTask?.cancel()
        activityTask?.cancel()
        _ = scheduler.reduce(.refreshCancelled)
        emit()
        refresh()
    }

    func observeHostStates(_ sink: @escaping @MainActor @Sendable (LeoHostRow) -> Void) {
        hostStateSink = sink
    }

    func handleHostStateChanged(_ row: LeoHostRow) {
        if let hostStateSink { Task { @MainActor in hostStateSink(row) } }
        guard row.hostID == selectedHost else { return }
        switch row.state {
        case .connected, .local:
            selectedHostAvailable = true
            if pollingRequested {
                process(scheduler.reduce(.sidebarVisibleCountChanged(1)))
            } else {
                refresh()
            }
        case .disconnected, .error:
            selectedHostAvailable = false
            snapshot = .init(rows: snapshot.rows, connectivity: .failed(message: row.error ?? "Host unavailable"), generation: snapshot.generation + 1)
            refreshTask?.cancel()
            activityTask?.cancel()
            _ = scheduler.reduce(.refreshCancelled)
            process(scheduler.reduce(.sidebarVisibleCountChanged(0)))
            pollTask?.cancel()
            emit()
        case .connecting, .unknown:
            break
        }
    }
}
