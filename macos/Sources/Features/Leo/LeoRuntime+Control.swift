import Foundation

extension LeoRuntime {
    /// What the control bar and the Agents-menu verbs may do for `row`
    /// (nil: nothing selected, a shell row, or disconnected), the one rule
    /// both read.
    func controlAvailability(for row: LeoAgentRow?) -> LeoAgentControlAvailability {
        LeoAgentControlAvailability(
            row: row, features: model.daemonFeatures, deniedHosts: control.deniedHosts, inFlight: row.flatMap { control.inFlight[$0.id] }
        )
    }
}
