import Foundation

enum LeoHostID: Hashable, Sendable, Codable {
    case local

    var displayName: String { "localhost" }
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

    var id: ID { ID(host: host, name: name) }
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
