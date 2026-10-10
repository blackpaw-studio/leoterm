import Foundation

/// B-013 in the feed: live `file_surfaced` events and every `/state`
/// fetch's `surfaced_files` feed one `LeoSurfacedFileIndex` for the
/// selected host (a host switch empties it). Rows get their own
/// incarnation's files at emission time. A live event new to the feed,
/// while connected, is also reported (`onFileSurfaced`) so its file can
/// open in the background (B-273, superseding D-088); a `/state` fetch's
/// files -- history, a reconnect's recovery -- are only badged.
extension LeoSidebarFeed {
    /// What the rows show: metadata and surfaced files overlaid (attention
    /// goes on top in `emit`).
    var displayedSnapshot: LeoSidebarSnapshot {
        snapshot.overlayingMetadata(metadata).overlayingSurfacedFiles(surfacedFiles)
            .overlayingEnvironments(environments, features: daemonFeatures)
    }

    func receiveSurfacedFile(_ file: LeoSurfacedFile) {
        let (index, isNew) = surfacedFiles.inserting(file)
        guard isNew else { return }
        surfacedFiles = index
        emit()
        guard !isDisconnected else { return }
        let (onFileSurfaced, host) = (onFileSurfaced, selectedHost)
        Task { await onFileSurfaced(host, file) }
    }

    func mergeSurfacedFiles(from state: [LeoObservedAgent]) {
        surfacedFiles = surfacedFiles.merging(state: state)
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their own incarnation's surfaced files. None while
    /// disconnected: the rows are stale.
    func overlayingSurfacedFiles(_ index: LeoSurfacedFileIndex) -> LeoSidebarSnapshot {
        let rows = connectivity.isDisconnected ? rows.map { $0.withSurfacedFiles([]) } : index.attach(to: rows)
        return LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
