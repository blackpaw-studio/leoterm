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

    struct ID: Hashable, Sendable {
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

    init(host: LeoHostID, name: String, template: String?, status: LeoAgentStatus, activity: Activity, actionDetail: String?, workspace: String? = nil, repo: String? = nil) {
        self.host = host
        self.name = name
        self.template = template
        self.status = status
        self.activity = activity
        self.actionDetail = actionDetail
        self.workspace = workspace
        self.repo = repo
    }

    var id: ID { ID(host: host, name: name) }
    var identity: LeoAgentIdentity { LeoAgentIdentity(host: host, name: name, workspace: workspace, repo: repo) }
}

enum LeoConnectivity: Equatable, Sendable {
    case loading
    case connected
    case failed(message: String)
}

struct LeoSidebarSnapshot: Equatable, Sendable {
    let rows: [LeoAgentRow]
    let connectivity: LeoConnectivity
    let generation: Int
}

enum AttachDisposition: Sendable { case reuseOrTab, newWindow }

struct LeoSidebarActivity: Equatable, Sendable {
    let activity: LeoAgentRow.Activity
    let detail: String?
}
