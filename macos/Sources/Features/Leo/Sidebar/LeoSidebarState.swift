import Foundation

enum LeoHostID: Hashable, Sendable, Codable {
    case local
    case remote(String)

    var displayName: String {
        switch self {
        case .local: "localhost"
        case .remote(let name): name
        }
    }
}

struct LeoAgentRow: Identifiable, Equatable, Sendable {
    enum Activity: String, Equatable, Sendable { case working, idle, unknown }

    struct ID: Hashable, Sendable, Codable {
        let host: LeoHostID
        let name: String
    }

    let host: LeoHostID
    let name: String
    let template: String?
    let status: LeoAgentStatus
    let activity: Activity
    let actionDetail: String?
    let workspace: String?
    let repo: String?
    /// The attention badge, overlaid by `LeoSidebarFeed` at emission time
    /// from `LeoAttentionReducer` (never stored on the feed's own rows).
    let attention: LeoAttentionBadge?
    /// Why the agent needs input, overlaid with `attention` (B-258). Nil
    /// unless the badge is needs_input and the daemon gave a reason.
    let attentionReason: LeoAttentionReason?
    /// The list's `started_at`: which incarnation this row is (D-074).
    let startedAt: String?
    /// Last-active time and task from a `/state` snapshot of this very
    /// incarnation, overlaid by `LeoSidebarFeed` at emission time.
    let metadata: LeoAgentMetadata?
    /// Files this very incarnation surfaced (B-013), newest last, overlaid
    /// by `LeoSidebarFeed` at emission time. Seen or not is the model's.
    let surfacedFiles: [LeoSurfacedFile]
    /// The agent's last turn, overlaid by `LeoSidebarFeed` at emission time
    /// (B-259); nil unless the daemon advertised `bridge_turns`.
    let lastTurn: LeoTurnPreview?
    /// A compaction in progress, overlaid at emission time from the
    /// `agent_compaction` events (B-261); nil otherwise.
    let compaction: LeoRowCompaction?

    init(
        host: LeoHostID, name: String, template: String?, status: LeoAgentStatus, activity: Activity, actionDetail: String?,
        workspace: String? = nil, repo: String? = nil, attention: LeoAttentionBadge? = nil, attentionReason: LeoAttentionReason? = nil,
        startedAt: String? = nil, metadata: LeoAgentMetadata? = nil, surfacedFiles: [LeoSurfacedFile] = [],
        lastTurn: LeoTurnPreview? = nil, compaction: LeoRowCompaction? = nil
    ) {
        self.host = host
        self.name = name
        self.template = template
        self.status = status
        self.activity = activity
        self.actionDetail = actionDetail
        self.workspace = workspace
        self.repo = repo
        self.attention = attention
        self.attentionReason = attentionReason
        self.startedAt = startedAt
        self.metadata = metadata
        self.surfacedFiles = surfacedFiles
        self.lastTurn = lastTurn
        self.compaction = compaction
    }

    func withAttention(_ attention: LeoAttentionBadge?, reason: LeoAttentionReason? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: template, status: status, activity: activity, actionDetail: actionDetail,
            workspace: workspace, repo: repo, attention: attention, attentionReason: reason, startedAt: startedAt,
            metadata: metadata, surfacedFiles: surfacedFiles, lastTurn: lastTurn, compaction: compaction
        )
    }

    func withMetadata(_ metadata: LeoAgentMetadata?) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: template, status: status, activity: activity, actionDetail: actionDetail,
            workspace: workspace, repo: repo, attention: attention, attentionReason: attentionReason,
            startedAt: startedAt, metadata: metadata, surfacedFiles: surfacedFiles, lastTurn: lastTurn, compaction: compaction
        )
    }

    func withSurfacedFiles(_ files: [LeoSurfacedFile]) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: template, status: status, activity: activity, actionDetail: actionDetail,
            workspace: workspace, repo: repo, attention: attention, attentionReason: attentionReason,
            startedAt: startedAt, metadata: metadata, surfacedFiles: files, lastTurn: lastTurn, compaction: compaction
        )
    }

    func withLastTurn(_ lastTurn: LeoTurnPreview?) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: template, status: status, activity: activity, actionDetail: actionDetail,
            workspace: workspace, repo: repo, attention: attention, attentionReason: attentionReason,
            startedAt: startedAt, metadata: metadata, surfacedFiles: surfacedFiles, lastTurn: lastTurn, compaction: compaction
        )
    }

    func withCompaction(_ compaction: LeoRowCompaction?) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: template, status: status, activity: activity, actionDetail: actionDetail,
            workspace: workspace, repo: repo, attention: attention, attentionReason: attentionReason,
            startedAt: startedAt, metadata: metadata, surfacedFiles: surfacedFiles, lastTurn: lastTurn, compaction: compaction
        )
    }

    var id: ID { ID(host: host, name: name) }
    var identity: LeoAgentIdentity { LeoAgentIdentity(host: host, name: name, workspace: workspace, repo: repo) }
}

enum LeoConnectivity: Equatable, Sendable {
    case loading
    case connected
    case failed(message: String)
    /// A live connection dropped (stream end, tunnel exit, failed wake
    /// check): rows stay, dimmed and inert, until the user's Retry lands a
    /// fresh list (D-061). `reason` is raw; it's sanitized when rendered.
    /// `isRetrying` while that Retry is in flight.
    case disconnected(reason: String, isRetrying: Bool)

    var isDisconnected: Bool {
        if case .disconnected = self { true } else { false }
    }
}

struct LeoSidebarSnapshot: Equatable, Sendable {
    let rows: [LeoAgentRow]
    let connectivity: LeoConnectivity
    let generation: Int
    let listRefreshSucceeded: Bool
    /// Agents on this host needing attention that focus hasn't acknowledged
    /// -- the Dock badge count. Overlaid at emission time, like row badges.
    let attentionCount: Int
    /// Live dispatches nested under each agent row, by agent name (B-257).
    /// Overlaid at emission time from `LeoDispatchTree`; empty unless the
    /// daemon advertised `dispatch_tree` and the connection is live.
    let dispatchChildren: [String: [LeoDispatchNode]]
    /// What the connected daemon advertised on its hello (B-262 reads
    /// `agent_control`); `.none` while disconnected. Set last, at emission
    /// time, by `advertising(_:)`.
    let features: LeoDaemonFeatures

    init(
        rows: [LeoAgentRow], connectivity: LeoConnectivity, generation: Int, listRefreshSucceeded: Bool = false, attentionCount: Int = 0,
        dispatchChildren: [String: [LeoDispatchNode]] = [:], features: LeoDaemonFeatures = .none
    ) {
        self.features = features
        self.rows = rows
        self.connectivity = connectivity
        self.generation = generation
        self.listRefreshSucceeded = listRefreshSucceeded
        self.attentionCount = attentionCount
        self.dispatchChildren = dispatchChildren
    }

    /// Returns a copy with `rows` replaced and `connectivity`/`generation`
    /// carried over from `self` explicitly. `listRefreshSucceeded` has no
    /// default here on purpose -- every reconstruction site (list refresh,
    /// activity overlay, activity-state fetch) has a different right answer
    /// for it, and `LeoSidebarSnapshot`'s own memberwise `init` silently
    /// defaulting it to `false` is exactly what caused a list refresh's
    /// `true` to be lost by a later same-refresh reconstruction. Forcing
    /// callers to state it keeps that from recurring.
    func advertising(_ features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation, listRefreshSucceeded: listRefreshSucceeded,
            attentionCount: attentionCount, dispatchChildren: dispatchChildren, features: connectivity.isDisconnected ? .none : features
        )
    }

    func replacingRows(_ rows: [LeoAgentRow], listRefreshSucceeded: Bool) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation, listRefreshSucceeded: listRefreshSucceeded,
            dispatchChildren: dispatchChildren
        )
    }
}

/// Where a sidebar attach goes: the window's content area (a click,
/// Return), or a new window (⌘-click, ⌥-double-click, Open in New
/// Window). An agent already on screen is focused either way (B-055).
enum AttachDisposition: Sendable { case content, newWindow }

struct LeoSidebarActivity: Equatable, Sendable {
    let activity: LeoAgentRow.Activity
    let detail: String?
}
