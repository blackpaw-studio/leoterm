import Foundation
import LeoKit

/// What Settings ▸ This Mac shows, derived from sources the app already has.
/// A field whose source is missing is nil, so the view omits its row instead
/// of stubbing it.
struct LeoThisMacOverview: Equatable {
    struct Summary: Equatable {
        let title: String
        let detail: String
    }

    /// "No agents", "1 agent", "14 agents": every agent on this Mac.
    let agentCountText: String
    /// The connection badge; nil before the registry has a status.
    let status: LeoMachineStatus?
    /// Why This Mac is unreachable, when it is.
    let reason: String?
    /// The managed daemon's state in words.
    let daemon: Summary
    /// The managed state's version, else what the daemon reported.
    let version: String?
    /// The state's actions (banner actions, and the start action while offline).
    let actions: [LeoManagedSettingsAction]
    let configPath: String?
    /// The local socket; only while connected.
    let socketPath: String?

    init(
        managed: LeoManagedStatus, presentation: LeoManagedPresentation, connection: LeoHostConnectionState?, status: LeoMachineStatus?,
        service: LeoServiceStatus?, agentCount: Int, daemonVersion: String?
    ) {
        switch agentCount {
        case 0: agentCountText = "No agents"
        case 1: agentCountText = "1 agent"
        default: agentCountText = "\(agentCount) agents"
        }
        self.status = status
        if case .failed(let message)? = status { reason = message } else { reason = nil }
        let words = managed.settingsSummary
        daemon = Summary(title: words.title, detail: words.detail)
        if case .managed(let managedVersion?) = managed {
            version = managedVersion
        } else {
            version = daemonVersion
        }
        actions = presentation.settingsActions(isConnected: status == .connected)
        configPath = service.map(\.configPath).flatMap { $0.isEmpty ? nil : $0 }
        if case .connected(let socketPath)? = connection { self.socketPath = socketPath } else { socketPath = nil }
    }
}
