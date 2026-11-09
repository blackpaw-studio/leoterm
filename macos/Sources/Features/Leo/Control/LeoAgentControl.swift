import Foundation
import LeoKit

/// What the toolbar's Interrupt and the Agents-menu verbs may do for one
/// selected row (B-262). Pure: the daemon must advertise `agent_control` (never
/// invent a capability), the host must not have refused the token, and the
/// agent must be running. One action at a time.
struct LeoAgentControlAvailability: Equatable, Sendable {
    let canInterrupt: Bool
    let canCompact: Bool
    let canClear: Bool

    /// Full, for the banner.
    static let deniedMessage = "This host's token can't control agents (operator access required)."

    private static let none = Self(canInterrupt: false, canCompact: false, canClear: false)

    init(row: LeoAgentRow?, features: LeoDaemonFeatures, deniedHosts: Set<LeoHostID>, inFlight: LeoControlVerb?) {
        guard let row, features.contains(.agentControl), !deniedHosts.contains(row.host), row.movedTo == nil, row.status == .running else {
            self = .none
            return
        }
        let idle = inFlight == nil
        // Interrupt stops work in progress: an idle agent has none. An unknown
        // activity (a daemon without activity data) counts as working.
        self.init(canInterrupt: idle && row.activity != .idle, canCompact: idle, canClear: idle)
    }

    private init(canInterrupt: Bool, canCompact: Bool, canClear: Bool) {
        self.canInterrupt = canInterrupt
        self.canCompact = canCompact
        self.canClear = canClear
    }
}
