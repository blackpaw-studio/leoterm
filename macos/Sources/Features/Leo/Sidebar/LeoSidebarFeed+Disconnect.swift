import Foundation

/// The disconnected state (B-007, D-061): entered when the activity stream
/// drops, a live tunnel dies or the one wake check fails. Rows stay with
/// their activity cleared; every stream, refresh, poll and attention timer
/// stops, and nothing restarts until a Retry reconnects (see
/// `updateConnection`'s same-host retry path): the user's Reconnect, or
/// `LeoMachineRegistry`'s backoff, which `LeoRuntime` starts when it sees
/// this drop. The feed itself keeps no timers, ever.
extension LeoSidebarFeed {
    var isDisconnected: Bool { snapshot.connectivity.isDisconnected }

    /// Enters the disconnected state with `reason`. The DEBUG
    /// `LEO_FORCE_DISCONNECTED` fixture enters it through
    /// `forceDisconnectAfterFirstList`.
    func disconnect(reason: String) {
        guard running else { return }
        Self.logger.log("disconnect: reason=\(reason, privacy: .public)")
        cancelBaselineRetry()
        eventTask?.cancel()
        eventTask = nil
        refreshTask?.cancel()
        activityTask?.cancel()
        cancelLivenessCheck()
        sseRefreshTask?.cancel()
        sseRefreshTask = nil
        activityCoalesceTask?.cancel()
        activityCoalesceTask = nil
        activityCoalescer = LeoActivityCoalescer()
        activityByName = [:]
        resetMetadata()
        resetTurns()
        resetCompactions()
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
                            workspace: $0.workspace, repo: $0.repo, startedAt: $0.startedAt, wakeOnMessage: $0.wakeOnMessage,
                            movedTo: $0.movedTo, movedAt: $0.movedAt)
            },
            connectivity: .disconnected(reason: reason, isRetrying: false),
            generation: snapshot.generation + 1
        )
        emit()
    }

    /// One liveness check after the Mac wakes (single shot, never
    /// repeated): the agent list, bounded by `fetchList`'s deadline. A
    /// failure disconnects; a success changes nothing. Returns the check's
    /// token, or nil when none runs.
    @discardableResult
    func checkLiveness() -> Int? {
        guard running, selectedHostAvailable, !isDisconnected else { return nil }
        cancelLivenessCheck()
        let token = livenessToken
        livenessTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.fetchList()
                await self.livenessCheckFinished(.success(()), token: token)
            } catch is CancellationError {
                return
            } catch {
                await self.livenessCheckFinished(.failure(error), token: token)
            }
        }
        return token
    }

    /// Cancels the check in flight and retires its token, so a result it
    /// may still deliver is recognized as stale.
    func cancelLivenessCheck() {
        livenessTask?.cancel()
        livenessTask = nil
        livenessToken += 1
    }

    /// Applies check `token`'s result -- only if it's still the latest
    /// check: a superseded one (its error already on its way when the next
    /// wake cancelled it) must never disconnect a healthy connection.
    func livenessCheckFinished(_ result: Result<Void, Error>, token: Int) {
        guard token == livenessToken, selectedHostAvailable, !isDisconnected else { return }
        livenessTask = nil
        if case .failure(let error) = result { disconnect(reason: error.localizedDescription) }
    }
}

#if DEBUG
/// The `LEO_FORCE_DISCONNECTED` fixture (B-166): armed in the feed so it
/// fires in order with the feed's own connections, however their phases
/// and lists interleave.
extension LeoSidebarFeed {
    /// A connection `LeoMachineRegistry` handed out: its generations start
    /// at 1. Generation 0 is This Mac's feed from launch, listing on its own
    /// before the registry's first connect. Forced down there, that connect
    /// would read as the user's Retry and reconnect, and the banner would
    /// never show.
    var isRegistryConnection: Bool { connectionGeneration > 0 }

    /// Disconnects with `reason` once, when a list lands on a registry
    /// connection -- at once if the current one has listed already.
    func forceDisconnectAfterFirstList(reason: String) {
        forcedDisconnectReason = reason
        forceDisconnectIfDue()
    }

    /// Fires the armed drop if a list has landed on this registry
    /// connection. Returns whether it fired.
    @discardableResult
    func forceDisconnectIfDue() -> Bool {
        guard let reason = forcedDisconnectReason, running, isRegistryConnection, snapshot.connectivity == .connected else { return false }
        forcedDisconnectReason = nil
        disconnect(reason: reason)
        return true
    }
}
#endif
