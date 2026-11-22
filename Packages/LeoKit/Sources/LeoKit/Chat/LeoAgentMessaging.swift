import Foundation

/// An agent on a specific machine: what "tell an agent" can send to.
public struct LeoAgentTarget: Codable, Equatable, Hashable, Sendable {
    public let machineID: String
    public let machineName: String
    public let agent: String

    public init(machineID: String, machineName: String, agent: String) {
        self.machineID = machineID
        self.machineName = machineName
        self.agent = agent
    }

    /// The identity a Control or Shortcut stores: machine plus agent name.
    public var pushTarget: LeoPushTarget { LeoPushTarget(daemonID: machineID, agent: agent) }

    /// The agent's name, or `name · machine` when the same name exists on
    /// more than one machine in `targets`.
    public func displayName(among targets: [LeoAgentTarget]) -> String {
        let sameName = targets.filter { $0.agent == agent }
        let machines = Set(sameName.map(\.machineID))
        return machines.count > 1 ? "\(agent) · \(machineName)" : agent
    }
}

/// What to do with a "tell an agent" request, given the configured agent
/// (if any) and the agents the paired machines reported.
public enum LeoAgentResolution: Equatable, Sendable {
    /// The configured agent exists: send with no prompt.
    case send(LeoAgentTarget)
    /// Ask which agent. `unavailable` names a configured agent that is
    /// gone, so the app can say so first.
    case ask(options: [LeoAgentTarget], unavailable: String?)
    /// Nothing is paired.
    case noMachines

    public static func resolve(configured: LeoPushTarget?, available: [LeoAgentTarget], machineCount: Int) -> Self {
        guard machineCount > 0 else { return .noMachines }
        guard let configured else { return .ask(options: available, unavailable: nil) }
        if let match = available.first(where: { $0.pushTarget == configured }) { return .send(match) }
        return .ask(options: available, unavailable: configured.agent)
    }
}
