import Foundation

/// Coalescing of `agentActivity` SSE events -- see `LeoActivityCoalescer`
/// for the pure buffering logic and `LeoSidebarFeed`'s `activityCoalescer`/
/// `activityCoalesceTask` for the state this drives.
extension LeoSidebarFeed {
    /// Merges a batch of buffered `agentActivity` events into
    /// `activityByName` in one pass (last write wins per agent, already
    /// guaranteed by `LeoActivityCoalescer`).
    func mergeIntoActivityByName(_ events: [LeoObserveEvent]) {
        for event in events {
            guard case let .agentActivity(_, _, name, activity, currentAction, _) = event else { continue }
            activityByName[name] = LeoSidebarActivity(activity: Self.activity(activity), detail: currentAction?.detail)
        }
    }

    /// Cancels any pending flush timer and merges whatever's currently
    /// buffered into `activityByName` -- used both by the flush timer
    /// itself and by any other emission path (lifecycle events, list
    /// refreshes, activity-state fetches) so a still-pending coalescing
    /// window is never silently dropped or left to race a later emission.
    func drainCoalescedActivity() {
        activityCoalesceTask?.cancel()
        activityCoalesceTask = nil
        let events = activityCoalescer.drain()
        mergeIntoActivityByName(events)
        // Asked for by whatever runs next (a list refresh or lifecycle
        // event), or dropped by a recovery that fetches `/state` anyway.
        if !events.isEmpty { metadataRefreshPending = true }
    }

    func scheduleActivityFlush() {
        activityCoalesceTask?.cancel()
        activityCoalesceTask = Task { [weak self, sleeper] in
            do {
                try await sleeper(UInt64(Self.activityCoalesceInterval * 1_000_000_000))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Leo sidebar activity-coalescing sleep failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.flushActivity()
        }
    }

    func flushActivity() {
        activityCoalesceTask = nil
        let events = activityCoalescer.drain()
        guard !events.isEmpty else { return }
        mergeIntoActivityByName(events)
        // The events only say something changed; the metadata comes from a
        // fresh snapshot, never from their payloads (D-074).
        requestMetadataRefresh()
        // Not a list refresh -- `LeoSidebarModel.receive` only clears row
        // errors when `listRefreshSucceeded` is true, which a coalesced
        // activity-only flush never is (matches the old per-event
        // `applyActivity`, which also always defaulted it to false).
        let updated = snapshot.replacingRows(LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), listRefreshSucceeded: false)
        guard updated != snapshot else { return }
        snapshot = updated
        emit()
    }

    /// No host filtering: `activitySource` is already scoped to exactly one
    /// connection (see `LeoSidebarFeedTarget.updateConnection`).
    static func activities(_ agents: [LeoObservedAgent]) -> [String: LeoSidebarActivity] {
        Dictionary(agents.map {
            ($0.name, LeoSidebarActivity(activity: activity($0.activity), detail: $0.currentAction?.detail))
        }, uniquingKeysWith: { _, latest in latest })
    }

    static func activity(_ activity: LeoActivity?) -> LeoAgentRow.Activity {
        switch activity {
        case .working: .working
        case .idle: .idle
        case .unknown, nil: .unknown
        }
    }
}
