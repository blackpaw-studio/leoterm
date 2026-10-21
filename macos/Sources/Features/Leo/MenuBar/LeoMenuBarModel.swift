import Foundation
import LeoKit

struct LeoMenuBarInputs: Equatable {
    let snapshot: LeoSidebarSnapshot
    /// The running daemon's version; nil until a hello reports it.
    let version: String?
    let isManaged: Bool
    let serverOnly: Bool
    let isRestarting: Bool
    let hasLogFile: Bool
}

struct LeoMenuBarAgent: Equatable {
    enum State: Equatable { case running, starting, stopped, other }

    let id: LeoAgentRow.ID
    let name: String
    let state: State
    let needsAttention: Bool
}

enum LeoMenuBarAction: Equatable, Hashable {
    case pairDevice, restartDaemon, releaseToCLI, openLogs, toggleServerOnly, openLeo, quit
}

enum LeoMenuBarItem: Equatable {
    case status(title: String, detail: String?)
    case agents(title: String, isEnabled: Bool, agents: [LeoMenuBarAgent])
    case separator
    case action(LeoMenuBarAction, title: String, isEnabled: Bool, isChecked: Bool)
}

/// What the menu bar extra shows (A11), pure so every state is tested; the
/// controller only renders it.
enum LeoMenuBarModel {
    static let preferenceKey = "leo.menuBarExtra"

    static func items(_ inputs: LeoMenuBarInputs) -> [LeoMenuBarItem] {
        let snapshot = inputs.snapshot
        let isLocal = (snapshot.advertised.host ?? .local) == .local
        let agents = agents(in: snapshot)
        // B4: only the app's own daemon can be handed back.
        let release: [LeoMenuBarItem] = inputs.isManaged
            ? [.action(.releaseToCLI, title: "Release to CLI…", isEnabled: !inputs.isRestarting, isChecked: false)]
            : []
        return [
            status(inputs),
            .agents(
                title: agents.isEmpty ? "No Agents" : "Agents",
                isEnabled: !agents.isEmpty && !snapshot.connectivity.isDisconnected,
                agents: agents
            ),
            .separator,
            .action(
                .pairDevice, title: "Pair a Device…",
                isEnabled: isLocal && snapshot.connectivity == .connected, isChecked: false
            ),
            .action(
                .restartDaemon, title: inputs.isRestarting ? "Restarting Daemon…" : "Restart Daemon",
                isEnabled: isLocal && !inputs.isRestarting, isChecked: false
            ),
        ] + release + [
            .action(.openLogs, title: "Open Logs", isEnabled: inputs.hasLogFile, isChecked: false),
            .separator,
            .action(.toggleServerOnly, title: "Run as Server Only", isEnabled: true, isChecked: inputs.serverOnly),
            .action(.openLeo, title: "Open Leo", isEnabled: true, isChecked: false),
            .separator,
            .action(.quit, title: "Quit Leo", isEnabled: true, isChecked: false),
        ]
    }

    static func isVisible(preference: Bool, serverOnly: Bool) -> Bool { preference || serverOnly }

    /// On unless the user turned it off.
    static func preference(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    private static func status(_ inputs: LeoMenuBarInputs) -> LeoMenuBarItem {
        switch inputs.snapshot.connectivity {
        case .loading:
            return .status(title: "Connecting to daemon…", detail: nil)
        case .failed:
            return .status(title: "Daemon not running", detail: nil)
        case .disconnected(_, let isRetrying):
            return .status(title: "Daemon disconnected", detail: isRetrying ? "Reconnecting…" : nil)
        case .connected:
            let parts = [inputs.version.map { "v\($0)" }, inputs.isManaged ? "managed by Leo" : nil].compactMap { $0 }
            return .status(title: "Daemon running", detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
        }
    }

    private static func agents(in snapshot: LeoSidebarSnapshot) -> [LeoMenuBarAgent] {
        snapshot.rows
            .map { row in
                LeoMenuBarAgent(
                    id: row.id, name: row.name, state: state(of: row.status),
                    needsAttention: row.attention == .needsInput || row.attention == .errored
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func state(of status: LeoAgentStatus) -> LeoMenuBarAgent.State {
        switch status {
        case .running: .running
        case .starting: .starting
        case .stopped: .stopped
        case .unknown: .other
        }
    }
}
