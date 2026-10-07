import Foundation

/// List/activity-state fetch machinery for `LeoSidebarFeed`: racing the
/// agent-list fetch against a deadline, and fetching+applying a fresh
/// activity-state snapshot after a list refresh that needed one.
extension LeoSidebarFeed {
    func fetchActivityState(generation: Int) {
        activityTask?.cancel()
        let metadataRequest = nextMetadataRequest()
        let dispatchMark = dispatchTree.mark
        // This baseline covers whatever was owed until now; only activity
        // drained after it starts needs a snapshot of its own.
        metadataRefreshPending = false
        activityTask = Task { [weak self, activitySource] in
            do {
                let state = try await Self.fetchState(from: activitySource)
                guard let self else { return }
                await self.applyActivityState(state, generation: generation, metadataRequest: metadataRequest, dispatchMark: dispatchMark)
            } catch is CancellationError {
                return
            } catch {
                await self?.activityStateFailed(generation: generation)
            }
        }
    }

    /// Leaves the baseline pending so the next refresh (poll, SSE or manual)
    /// retries it; no retry timer of its own.
    private func activityStateFailed(generation: Int) {
        guard running, generation == snapshot.generation else { return }
        needsState = true
    }

    func fetchList() async throws -> [LeoAgent] {
        let daemon = daemon
        let sleeper = sleeper
        let race = LeoListFetchRace()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let listTask = Task {
                    do {
                        race.finish(.success(try await daemon.listAgents()), winner: .list)
                    } catch {
                        race.finish(.failure(error), winner: .list)
                    }
                }
                let deadlineTask = Task {
                    do {
                        try await sleeper(5_000_000_000)
                        race.finish(.failure(LeoSidebarFeedError.listTimedOut), winner: .deadline)
                    } catch {
                        race.finish(.failure(error), winner: .deadline)
                    }
                }
                race.install(listTask: listTask, deadlineTask: deadlineTask)
            }
        } onCancel: {
            race.cancel()
        }
        return try result.get()
    }

    func applyActivityState(_ observed: LeoObservedState, generation: Int, metadataRequest: Int, dispatchMark: Int) {
        guard running, generation == snapshot.generation else { return }
        let state = observed.agents
        // Dispatches follow the same request order as metadata: a baseline
        // older than a snapshot already applied must not touch them.
        if applyMetadata(state, request: metadataRequest, generation: generation) {
            applyDispatchBaseline(observed.dispatches, since: dispatchMark)
        }
        mergeSurfacedFiles(from: state)
        // `state` is the authoritative baseline as of when the fetch
        // started; anything coalesced since then is newer, so it's merged
        // in on top rather than lost.
        activityByName = Self.activities(state)
        applyAttentionBaseline(state)
        syncBaselinePending()
        drainCoalescedActivity()
        // Not a list refresh -- `LeoSidebarModel.receive` only clears row
        // errors when `listRefreshSucceeded` is true, and an activity-state
        // fetch fixing/breaking an agent's activity overlay isn't that.
        snapshot = snapshot.replacingRows(LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), listRefreshSucceeded: false)
        emit()
        // Activity drained here (or pending from before) may postdate
        // `state`: its snapshot follows now.
        if metadataRefreshPending { requestMetadataRefresh() }
    }

    static func fetchState(from source: LeoSidebarActivitySource) async throws -> LeoObservedState {
        try await withThrowingTaskGroup(of: LeoObservedState.self) { group in
            group.addTask { try await source.fetchState() }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw LeoSidebarFeedError.activityStateTimedOut
            }
            defer { group.cancelAll() }
            guard let state = try await group.next() else { return LeoObservedState(agents: []) }
            return state
        }
    }
}
