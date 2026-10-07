import Foundation

/// Row metadata (B-011, D-074): last-active time and current task, taken
/// only from whole `/state` snapshots -- never merged from `agent_activity`
/// payloads. An activity or lifecycle event only asks for a fresh snapshot
/// (polls never do): one fetch in flight at a time, with one trailing refetch for
/// whatever asked meanwhile. Snapshots apply in request order (an older one
/// landing late is dropped), only within the generation that asked, and
/// attach to rows by `started_at` (see `LeoAgentMetadataIndex`).
extension LeoSidebarFeed {
    /// Asks for a fresh snapshot. A no-op while recovering or while a
    /// `/state` baseline is pending: that fetch carries the metadata too.
    func requestMetadataRefresh() {
        guard running, selectedHostAvailable, !isDisconnected, !recovering, !needsState else { return }
        guard metadataInFlight == nil else {
            metadataRefreshPending = true
            return
        }
        startMetadataFetch()
    }

    /// Reserves the next snapshot request number; results apply only in
    /// increasing order.
    func nextMetadataRequest() -> Int {
        metadataRequestSeq += 1
        return metadataRequestSeq
    }

    /// Applies snapshot `request` of generation `generation` as a whole,
    /// continuing the activity streaks of the one before it (B-063).
    /// Returns whether it was current enough to apply.
    @discardableResult
    func applyMetadata(_ state: [LeoObservedAgent], request: Int, generation: Int) -> Bool {
        guard running, generation == snapshot.generation, request > metadataAppliedSeq else { return false }
        metadataAppliedSeq = request
        metadata = LeoAgentMetadataIndex(state: state, previous: metadata)
        return true
    }

    /// Forgets every snapshot (host switch, reconnect, disconnect), and
    /// with them every activity streak: any fetch still in flight can no
    /// longer apply.
    func resetMetadata() {
        metadataTask?.cancel()
        metadataTask = nil
        metadataInFlight = nil
        metadataRefreshPending = false
        metadataAppliedSeq = metadataRequestSeq
        metadata = .empty
    }

    private func startMetadataFetch() {
        metadataRefreshPending = false
        let request = nextMetadataRequest()
        let generation = snapshot.generation
        let dispatchMark = dispatchTree.mark
        metadataInFlight = request
        metadataTask = Task { [weak self, activitySource] in
            let state: LeoObservedState?
            do {
                state = try await Self.fetchState(from: activitySource)
            } catch is CancellationError {
                return
            } catch {
                // Leaves what's shown; the next event or refresh asks again.
                Self.logger.error("Leo sidebar metadata fetch failed: \(String(describing: error), privacy: .public)")
                state = nil
            }
            await self?.metadataFetchFinished(state, request: request, generation: generation, dispatchMark: dispatchMark)
        }
    }

    private func metadataFetchFinished(_ observed: LeoObservedState?, request: Int, generation: Int, dispatchMark: Int) {
        // A reset retired this fetch, and a newer one may own the slot.
        guard metadataInFlight == request else { return }
        metadataInFlight = nil
        metadataTask = nil
        let shown = displayedSnapshot
        if let observed, generation == snapshot.generation {
            mergeSurfacedFiles(from: observed.agents)
            applyMetadata(observed.agents, request: request, generation: generation)
            mergeDispatchSnapshot(observed.dispatches, since: dispatchMark)
        }
        if displayedSnapshot != shown { emit() }
        if metadataRefreshPending { requestMetadataRefresh() }
    }
}

extension LeoSidebarSnapshot {
    /// Rows with the metadata of their own incarnation. None while
    /// disconnected: the rows are stale, so is what they were doing.
    func overlayingMetadata(_ index: LeoAgentMetadataIndex) -> LeoSidebarSnapshot {
        let rows = connectivity.isDisconnected ? rows.map { $0.withMetadata(nil) } : index.attach(to: rows)
        return LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
