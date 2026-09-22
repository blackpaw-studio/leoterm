import Foundation

/// Wiring of `LeoAttentionReducer` into `LeoSidebarFeed`: every decoded
/// event/baseline/focus change goes through the reducer, a single deadline
/// task drives its 300 ms commit window, and `emit()` overlays the result
/// (row badges + Dock count) onto the outgoing snapshot.
extension LeoSidebarFeed {
    func receiveAttention(_ event: LeoObserveEvent) {
        switch event {
        case .agentActivity(_, _, let agent, _, _, let signal?):
            attention.receive(agent: agent, signal: signal, now: now())
        case .agentSpawned(_, _, let agent, let signal):
            attention.resetAgent(agent.name)
            if let signal { attention.receive(agent: agent.name, signal: signal, now: now()) }
        case .hello(_, _, _, _, let bootID):
            guard attention.observeBoot(bootID) else { return }
            daemonRestarted(event)
        default:
            return
        }
        scheduleAttentionTick()
    }

    /// A restart discards revisions, so a baseline from the new daemon is
    /// required even when a recovery is already in flight (its state fetch
    /// may predate the restart); `receive`'s normal hello path covers the
    /// case where none is.
    private func daemonRestarted(_ hello: LeoObserveEvent) {
        needsState = true
        syncBaselinePending()
        guard recovering else { return }
        process(scheduler.reduce(.sseEvent(hello)))
    }

    /// Keeps the scheduler's ordinary poll running while a baseline is
    /// pending, even with SSE connected, so a failed or stale list or
    /// `/state` fetch is retried by the next tick -- no timer of its own.
    func syncBaselinePending() {
        process(scheduler.reduce(.baselinePendingChanged(needsState || attention.isAwaitingBaseline)))
    }

    func applyAttentionBaseline(_ state: [LeoObservedAgent]) {
        let baseline = state.reduce(into: [String: LeoAttentionSignal]()) { result, agent in
            if let signal = agent.attention { result[agent.name] = signal }
        }
        attention.applyBaseline(baseline)
        scheduleAttentionTick()
    }

    /// `mark` is `attention.membershipMark` read when the list fetch
    /// started: an agent spawned while it was in flight stays.
    func retainAttention(for rows: [LeoAgentRow], listedSince mark: Int) {
        attention.retain(agents: Set(rows.map(\.name)), listedSince: mark)
        scheduleAttentionTick()
    }

    /// The agent whose attachment is focused (any host; the reducer ignores
    /// other hosts). Emits only when that changes what the sidebar or Dock
    /// shows.
    func setFocusedAgent(_ id: LeoAgentRow.ID?) {
        guard running else { return }
        let before = snapshot.overlayingAttention(attention)
        attention.focus(id)
        if snapshot.overlayingAttention(attention) != before { emit() }
    }

    /// (Re)arms the one deadline task for the reducer's earliest pending
    /// candidate. The deadline is authoritative once the sleeper returns,
    /// so an injected sleeper that fires early can't spin.
    func scheduleAttentionTick() {
        attentionTask?.cancel()
        attentionTask = nil
        guard running, let deadline = attention.nextDeadline else { return }
        let delay = max(0, deadline - now())
        attentionTask = Task { [weak self, sleeper] in
            do {
                try await sleeper(UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.attentionDeadlineReached(deadline)
        }
    }

    private func attentionDeadlineReached(_ deadline: TimeInterval) {
        attentionTask = nil
        let transitions = attention.tick(now: max(now(), deadline))
        scheduleAttentionTick()
        guard !transitions.isEmpty else { return }
        emit()
        let onAttentionTransitions = onAttentionTransitions
        Task { await onAttentionTransitions(transitions) }
    }
}

extension LeoSidebarSnapshot {
    /// Row badges and the Dock count from `reducer`, for rows of its host.
    func overlayingAttention(_ reducer: LeoAttentionReducer) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows.map { $0.withAttention(reducer.badge(for: $0.name, legacyActivity: $0.activity)) },
            connectivity: connectivity,
            generation: generation,
            listRefreshSucceeded: listRefreshSucceeded,
            attentionCount: reducer.dockCount(among: Set(rows.map(\.name)))
        )
    }
}
