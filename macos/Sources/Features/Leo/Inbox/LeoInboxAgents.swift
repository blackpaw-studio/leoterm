import Foundation
import LeoKit

/// The inbox's view of the sidebar: one `LeoInboxAgent` per listed agent,
/// with the live committed attention signal the feed overlaid on its row.
enum LeoInboxAgents {
    static func make(from snapshots: [LeoHostID: LeoSidebarSnapshot]) -> [LeoInboxAgent] {
        snapshots.flatMap { host, snapshot in
            snapshot.rows.filter { $0.movedTo == nil }.map { row in
                LeoInboxAgent(
                    id: row.id, name: row.displayName, machine: host.displayName, project: project(of: row),
                    signal: row.attentionSignal, isStale: snapshot.connectivity.isOffline
                )
            }
        }
    }

    /// The repo's name (`owner/repo` → `repo`), else the workspace folder.
    static func project(of row: LeoAgentRow) -> String? {
        let source = [row.repo, row.workspace].lazy.compactMap { $0 }.first { !$0.isEmpty }
        return source.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
