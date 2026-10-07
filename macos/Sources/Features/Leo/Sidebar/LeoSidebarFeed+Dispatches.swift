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
            $0.observeBoot(bootID)
            $0.setEnabled(LeoDaemonFeatures(features).contains(.dispatchTree))
        }
    }

    func receiveDispatch(_ dispatch: LeoDispatch) {
        updatingDispatches { $0.upsert(dispatch) }
    }

    /// A `/state` baseline; the caller emits. `mark` is `dispatchTree.mark`
    /// read when its fetch started.
    func applyDispatchBaseline(_ dispatches: [LeoDispatch], since mark: Int) {
        dispatchTree.applyBaseline(dispatches, since: mark)
    }

    /// A `/state` that isn't the activity baseline (a metadata snapshot):
    /// applied the same way, emitting only if what's shown changed.
    func mergeDispatchSnapshot(_ dispatches: [LeoDispatch], since mark: Int) {
        updatingDispatches { $0.applyBaseline(dispatches, since: mark) }
    }

    /// The connection dropped: its records are stale, but ids that ended
    /// stay remembered for the same daemon (a Retry's baseline follows).
    func clearDispatchRecords() {
        dispatchTree.applyBaseline([])
    }

    /// Host switch or stop: nothing carries over.
    func resetDispatches() {
        dispatchTree.reset()
    }

    private func updatingDispatches(_ change: (inout LeoDispatchTree) -> Void) {
        let shown = shownDispatches
        change(&dispatchTree)
        if shownDispatches != shown { emit() }
    }

    private var shownDispatches: [String: [LeoDispatchNode]] {
        snapshot.overlayingDispatches(dispatchTree).dispatchChildren
    }
}

extension LeoSidebarSnapshot {
    /// Each row's nested dispatches from `tree`. None while disconnected:
    /// the rows are stale, so is what they were running.
    func overlayingDispatches(_ tree: LeoDispatchTree) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount,
            dispatchChildren: connectivity.isDisconnected ? [:] : tree.projection(for: rows.map(\.name))
        )
    }
}
