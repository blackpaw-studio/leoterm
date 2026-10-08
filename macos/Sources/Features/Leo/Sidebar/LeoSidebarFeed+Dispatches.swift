import Foundation

/// B-257 in the feed: `LeoDispatchTree` for the selected host. hello says
/// whether the daemon has a dispatch source (`dispatch_tree`) and which
/// boot this is; `/state` baselines replace the records and
/// `dispatch_changed` upserts them. `emit()` overlays the nesting on the
/// rows, and only a change to what that overlay shows emits -- the 1 s
/// dispatch ticker republishes records whose tokens moved.
extension LeoSidebarFeed {
    func receiveDispatchHello(bootID: String?, features: [String]) {
        updatingDispatches {
            let rebooted = $0.observeBoot(bootID)
            let advertised = LeoDaemonFeatures(features)
            let toggled = $0.setEnabled(advertised.contains(.dispatchTree))
            $0.setStateSeq(advertised.contains(.stateSeq))
            return rebooted || toggled
        }
    }

    func receiveDispatch(_ dispatch: LeoDispatch, seq: Int? = nil) {
        updatingDispatches { $0.upsert(dispatch, seq: seq) }
    }

    /// `state_seq`: a hello is the moment the stream is subscribed, so a
    /// `/state` taken now covers everything created before it -- the
    /// create-between-GET-and-subscribe gap. Baselines apply in seq order,
    /// so an extra one is never wrong. (A hello that isn't a connect's
    /// already recovers with a full refetch.)
    func refetchStateAfterHello() {
        guard daemonFeatures.contains(.stateSeq) else { return }
        requestMetadataRefresh()
    }

    /// A `/state` baseline; the caller emits. `mark` is `dispatchTree.mark`
    /// read when its fetch started.
    func applyDispatchBaseline(_ dispatches: [LeoDispatch], since mark: Int, atSeq seq: Int? = nil) {
        dispatchTree.applyBaseline(dispatches, since: mark, atSeq: seq)
    }

    /// A `/state` that isn't the activity baseline (a metadata snapshot):
    /// applied the same way, emitting only if what's shown changed.
    func mergeDispatchSnapshot(_ dispatches: [LeoDispatch], since mark: Int, atSeq seq: Int? = nil) {
        updatingDispatches { $0.applyBaseline(dispatches, since: mark, atSeq: seq) }
    }

    /// Host switch or stop: nothing carries over.
    func resetDispatches() {
        dispatchTree.reset()
    }

    /// `change` reports whether the tree changed; only then are the shown
    /// nestings compared (the dispatch ticker makes this a hot path).
    private func updatingDispatches(_ change: (inout LeoDispatchTree) -> Bool) {
        let before = dispatchTree
        guard change(&dispatchTree) else { return }
        if shownDispatches(dispatchTree) != shownDispatches(before) { emit() }
    }

    private func shownDispatches(_ tree: LeoDispatchTree) -> [String: [LeoDispatchNode]] {
        snapshot.overlayingDispatches(tree).dispatchChildren
    }
}

extension LeoSidebarSnapshot {
    /// Each row's nested dispatches from `tree`. While disconnected they
    /// are the last-known ones (a drop must not blank them); the Retry's
    /// baseline reconciles them.
    func overlayingDispatches(_ tree: LeoDispatchTree) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount,
            dispatchChildren: tree.projection(for: rows.map(\.name))
        )
    }
}
