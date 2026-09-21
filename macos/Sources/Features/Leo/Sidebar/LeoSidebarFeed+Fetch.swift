import Foundation

/// List/activity-state fetch machinery for `LeoSidebarFeed`: racing the
/// agent-list fetch against a deadline, and fetching+applying a fresh
/// activity-state snapshot after a list refresh that needed one.
extension LeoSidebarFeed {
    func fetchActivityState(generation: Int) {
        activityTask?.cancel()
        activityTask = Task { [weak self, activitySource] in
            do {
                let state = try await Self.fetchState(from: activitySource)
                guard let self else { return }
                await self.applyActivityState(state, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
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

    func applyActivityState(_ state: [LeoObservedAgent], generation: Int) {
        guard running, generation == snapshot.generation else { return }
        // `state` is the authoritative baseline as of when the fetch
        // started; anything coalesced since then is newer, so it's merged
        // in on top rather than lost.
        activityByName = Self.activities(state)
        drainCoalescedActivity()
        // Not a list refresh -- `LeoSidebarModel.receive` only clears row
        // errors when `listRefreshSucceeded` is true, and an activity-state
        // fetch fixing/breaking an agent's activity overlay isn't that.
        snapshot = snapshot.replacingRows(LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), listRefreshSucceeded: false)
        emit()
    }

    static func fetchState(from source: LeoSidebarActivitySource) async throws -> [LeoObservedAgent] {
        try await withThrowingTaskGroup(of: [LeoObservedAgent].self) { group in
            group.addTask { try await source.fetchState() }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw LeoSidebarFeedError.activityStateTimedOut
            }
            defer { group.cancelAll() }
            guard let state = try await group.next() else { return [] }
            return state
        }
    }
}
