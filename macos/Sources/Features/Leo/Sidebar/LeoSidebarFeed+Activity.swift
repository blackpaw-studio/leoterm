import Foundation

/// Coalescing of `agentActivity` SSE events -- see `LeoActivityCoalescer`
/// for the pure buffering logic and `LeoSidebarFeed`'s `activityCoalescer`/
/// `activityCoalesceTask` for the state this drives.
extension LeoSidebarFeed {
    /// Merges a batch of buffered `agentActivity` events into
    /// `activityByName` in one pass (last write wins per agent, already
    /// guaranteed by `LeoActivityCoalescer`).
    func mergeIntoActivityByName(_ events: [LeoObserveEvent], latestWorkingAt: [String: Date] = [:]) {
        for event in events {
            guard case let .agentActivity(_, at, name, activity, currentAction, _) = event else { continue }
            activityByName[name] = LeoSidebarActivity.merging(
                activityByName[name], activity: Self.activity(activity), detail: currentAction?.detail, at: LeoTimestamp.parse(at)
            ).advanced(to: latestWorkingAt[name])
        }
    }

    func mergeIntoActivityByName(_ batch: LeoActivityCoalescer.Batch) {
        mergeIntoActivityByName(batch.events, latestWorkingAt: batch.latestWorkingAt)
    }

    /// Cancels any pending flush timer and merges whatever's currently
    /// buffered into `activityByName` -- used both by the flush timer
    /// itself and by any other emission path (lifecycle events, list
    /// refreshes, activity-state fetches) so a still-pending coalescing
    /// window is never silently dropped or left to race a later emission.
    func drainCoalescedActivity() {
        activityCoalesceTask?.cancel()
        activityCoalesceTask = nil
        mergeIntoActivityByName(activityCoalescer.drainBatch())
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
        let batch = activityCoalescer.drainBatch()
        guard !batch.events.isEmpty else { return }
        mergeIntoActivityByName(batch)
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
            ($0.name, LeoSidebarActivity(
                activity: activity($0.activity), detail: $0.currentAction?.detail, lastActivityAt: LeoTimestamp.parse($0.lastActivityAt)
            ))
        }, uniquingKeysWith: { _, latest in latest })
    }

    /// A `/observe/state` baseline over what's already applied: the
    /// baseline's agents and activity win, but a newer time from an event
    /// already applied is kept, and so are entries in `newer` (updated
    /// after the state fetch started) for agents the baseline lacks (B-010).
    static func baseline(
        _ agents: [LeoObservedAgent], over current: [String: LeoSidebarActivity], keeping newer: Set<String> = []
    ) -> [String: LeoSidebarActivity] {
        let fromState = activities(agents).reduce(into: [String: LeoSidebarActivity]()) { result, entry in
            result[entry.key] = entry.value.advanced(to: current[entry.key]?.lastActivityAt)
        }
        return current.filter { newer.contains($0.key) && fromState[$0.key] == nil }.merging(fromState) { _, state in state }
    }

    /// B-010's one rule for pruning at a list refresh, judged by when that
    /// list fetch started (`listMark`). A listed agent keeps its entry if
    /// the previous list had it too, if the entry was carried over for it
    /// (see below), or if the entry is newer than this fetch. An unlisted
    /// agent keeps it -- and it's carried -- only if the entry is newer
    /// than this fetch AND the previous list didn't have the agent: activity
    /// for a spawn this list predates, not a straggler from an agent this
    /// list just removed. So a gone agent's activity never reaches a
    /// namesake, and a new agent's never waits for a second event.
    static func survivors(
        _ activity: [String: LeoSidebarActivity], stamps: [String: Int], listed: Set<String>,
        previouslyListed: Set<String>, carried: Set<String>, listMark: Int
    ) -> [String: LeoSidebarActivity] {
        activity.filter { name, _ in
            let isNewer = (stamps[name] ?? 0) > listMark
            guard listed.contains(name) else { return isNewer && !previouslyListed.contains(name) }
            return previouslyListed.contains(name) || carried.contains(name) || isNewer
        }
    }

    func pruneActivity(listed: Set<String>, listMark: Int) {
        activityByName = Self.survivors(
            activityByName, stamps: activityStamps, listed: listed,
            previouslyListed: lastListedNames, carried: carriedActivityNames, listMark: listMark
        )
        activityStamps = activityStamps.filter { activityByName[$0.key] != nil }
        carriedActivityNames = Set(activityByName.keys).subtracting(listed)
        lastListedNames = listed
    }

    func nextActivityTick() -> Int {
        activityTick += 1
        return activityTick
    }

    /// Forgets all activity (boot, reconnect, disconnect, host switch).
    func resetActivity() {
        activityByName = [:]
        activityStamps = [:]
        carriedActivityNames = []
    }

    static func activity(_ activity: LeoActivity?) -> LeoAgentRow.Activity {
        switch activity {
        case .working: .working
        case .idle: .idle
        case .unknown, nil: .unknown
        }
    }
}
