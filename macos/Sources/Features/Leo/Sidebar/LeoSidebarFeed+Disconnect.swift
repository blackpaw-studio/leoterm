import Foundation

/// The disconnected state (B-007, D-061): entered when the activity stream
/// drops, a live tunnel dies or the one wake check fails. Rows stay with
/// their activity cleared; every stream, refresh, poll and attention timer
/// stops, and nothing restarts until the user's Retry reconnects (see
/// `updateConnection`'s same-host retry path). No timers, ever.
extension LeoSidebarFeed {
    var isDisconnected: Bool { snapshot.connectivity.isDisconnected }

    /// Enters the disconnected state with `reason`. Also the entry point
    /// for the DEBUG `LEO_FORCE_DISCONNECTED` fixture.
    func disconnect(reason: String) {
        guard running else { return }
        Self.logger.log("disconnect: reason=\(reason, privacy: .public)")
        eventTask?.cancel()
        eventTask = nil
        refreshTask?.cancel()
        activityTask?.cancel()
        livenessTask?.cancel()
        livenessTask = nil
        sseRefreshTask?.cancel()
        sseRefreshTask = nil
        activityCoalesceTask?.cancel()
        activityCoalesceTask = nil
        activityCoalescer = LeoActivityCoalescer()
        activityByName = [:]
        bufferedActivity = []
        attention.disconnect()
        scheduleAttentionTick()
        needsState = true
        recovering = false
        awaitingHello = false
        selectedHostAvailable = false
        _ = scheduler.reduce(.refreshCancelled)
        _ = scheduler.reduce(.sidebarVisibleCountChanged(0))
        pollTask?.cancel()
        pollTask = nil
        // A new generation: a list or state fetch still in flight from the
        // dropped connection can never land over this.
        snapshot = LeoSidebarSnapshot(
            rows: snapshot.rows.map {
                LeoAgentRow(host: $0.host, name: $0.name, template: $0.template, status: $0.status, activity: .unknown, actionDetail: nil,
                            workspace: $0.workspace, repo: $0.repo)
            },
            connectivity: .disconnected(reason: reason, isRetrying: false),
            generation: snapshot.generation + 1
        )
        emit()
    }

    /// One liveness check after the Mac wakes (single shot, never
    /// repeated): the agent list, bounded by `fetchList`'s deadline. A
    /// failure disconnects; a success changes nothing.
    func checkLiveness() {
        guard running, selectedHostAvailable, !isDisconnected else { return }
        livenessTask?.cancel()
        let generation = connectionGeneration
        livenessTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.fetchList()
            } catch is CancellationError {
                return
            } catch {
                await self.livenessCheckFailed(error, generation: generation)
            }
        }
    }

    private func livenessCheckFailed(_ error: Error, generation: Int) {
        livenessTask = nil
        guard generation == connectionGeneration, selectedHostAvailable, !isDisconnected else { return }
        disconnect(reason: error.localizedDescription)
    }
}
