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

/// A paired machine by identity: enough to name it and send to it.
public struct LeoAgentMachineRef: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What to do with a "tell an agent" request, given the configured agent
/// (if any) and the agents the paired machines reported.
public enum LeoAgentResolution: Equatable, Sendable {
    /// The configured agent exists, or lives on a machine that didn't
    /// answer (so the send fails into "Couldn't reach" and Retry): send
    /// with no prompt.
    case send(LeoAgentTarget)
    /// Ask which agent. `unavailable` names a configured agent that is
    /// gone, so the app can say so first.
    case ask(options: [LeoAgentTarget], unavailable: String?)
    /// No agent is known and a machine didn't answer, so there is nothing
    /// to ask about. `configured` is the agent the request named, if any.
    case unreachable(configured: LeoPushTarget?, machine: String)
    /// Nothing is paired.
    case noMachines

    /// `unreachable` lists the paired machines that failed or timed out
    /// when asked for their agents.
    public static func resolve(
        configured: LeoPushTarget?, available: [LeoAgentTarget], machineCount: Int, unreachable: [LeoAgentMachineRef] = []
    ) -> Self {
        guard machineCount > 0 else { return .noMachines }
        if let configured {
            if let match = available.first(where: { $0.pushTarget == configured }) { return .send(match) }
            if let down = unreachable.first(where: { $0.id == configured.daemonID }) {
                return .send(LeoAgentTarget(machineID: down.id, machineName: down.name, agent: configured.agent))
            }
        }
        if available.isEmpty, let down = unreachable.first {
            return .unreachable(configured: configured, machine: down.name)
        }
        return .ask(options: available, unavailable: configured?.agent)
    }
}
