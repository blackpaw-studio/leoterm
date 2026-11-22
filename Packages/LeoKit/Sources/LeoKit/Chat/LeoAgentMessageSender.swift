import Foundation

/// A paired machine as the sender sees it: who it is and how to list its agents.
public struct LeoAgentMachine: Sendable {
    public let id: String
    public let name: String
    public let agents: @Sendable () async throws -> [String]

    public init(id: String, name: String, agents: @escaping @Sendable () async throws -> [String]) {
        self.id = id
        self.name = name
        self.agents = agents
    }
}

/// The agents across every paired machine, plus how many machines there
/// are, so "nothing paired" and "nothing reachable" stay distinct.
public struct LeoAgentDirectory: Equatable, Sendable {
    public let machineCount: Int
    public let targets: [LeoAgentTarget]

    public init(machineCount: Int, targets: [LeoAgentTarget]) {
        self.machineCount = machineCount
        self.targets = targets
    }
}

/// What the apps say about a send. Each app words it with `String(localized:)`.
public enum LeoAgentSendOutcome: Equatable, Sendable {
    /// "Sent to <agent>."
    case sent(agent: String)
    /// "Couldn't reach <machine>." (also an auth failure: the machine can't be used.)
    case unreachable(machine: String)
    /// "<agent> isn't available."
    case agentMissing(agent: String)
}

/// What a failed send needs to be retried: the text is never dropped.
public struct LeoAgentRetryPayload: Equatable, Sendable {
    public let target: LeoPushTarget
    public let machine: String
    public let text: String

    public init(target: LeoPushTarget, machine: String, text: String) {
        self.target = target
        self.machine = machine
        self.text = text
    }
}

public enum LeoAgentSendResult: Equatable, Sendable {
    case sent(LeoAgentTarget)
    case unreachable(LeoAgentTarget, text: String)
    case unauthorized(LeoAgentTarget, text: String)
    case agentMissing(LeoAgentTarget)

    public var outcome: LeoAgentSendOutcome {
        switch self {
        case .sent(let target): .sent(agent: target.agent)
        case .unreachable(let target, _), .unauthorized(let target, _): .unreachable(machine: target.machineName)
        case .agentMissing(let target): .agentMissing(agent: target.agent)
        }
    }

    /// Non-nil for every failure the user can retry; a missing agent can't be.
    public var retryPayload: LeoAgentRetryPayload? {
        switch self {
        case .unreachable(let target, let text), .unauthorized(let target, let text):
            LeoAgentRetryPayload(target: target.pushTarget, machine: target.machineName, text: text)
        case .sent, .agentMissing: nil
        }
    }
}

/// Sends one message to one agent on one machine, and lists the agents a
/// "which agent?" prompt can offer. Platform-neutral: the app injects the
/// machines and how to reach each one's chat API.
public struct LeoAgentMessageSender: Sendable {
    /// How long a machine gets to list its agents before it is skipped.
    public static let defaultAgentListTimeout: Duration = .seconds(3)

    private let machines: @Sendable () async throws -> [LeoAgentMachine]
    private let chat: @Sendable (String) async throws -> any LeoChatClient
    private let deadline: @Sendable (String) async throws -> Void

    /// `deadline(machineID)` returns when that machine's agent list should
    /// be abandoned; tests inject it so no wall-clock wait is needed.
    public init(
        machines: @escaping @Sendable () async throws -> [LeoAgentMachine],
        chat: @escaping @Sendable (String) async throws -> any LeoChatClient,
        deadline: @escaping @Sendable (String) async throws -> Void = { _ in try await Task.sleep(for: LeoAgentMessageSender.defaultAgentListTimeout) }
    ) {
        self.machines = machines
        self.chat = chat
        self.deadline = deadline
    }

    public func send(_ target: LeoAgentTarget, text: String) async -> LeoAgentSendResult {
        guard let paired = try? await machines(), paired.contains(where: { $0.id == target.machineID }) else {
            return .agentMissing(target)
        }
        do {
            _ = try await chat(target.machineID).send(agent: target.agent, LeoChatDraft(text: text))
            return .sent(target)
        } catch {
            return Self.failure(error, target: target, text: text)
        }
    }

    public func agents() async -> LeoAgentDirectory {
        let paired = (try? await machines()) ?? []
        let listed = await withTaskGroup(of: [LeoAgentTarget].self) { group in
            for machine in paired {
                group.addTask { await agents(of: machine) }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return LeoAgentDirectory(machineCount: paired.count, targets: listed)
    }

    /// One machine's agents, or none when it fails or misses its deadline.
    private func agents(of machine: LeoAgentMachine) async -> [LeoAgentTarget] {
        let names: [String]? = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { try? await machine.agents() }
            group.addTask {
                try? await deadline(machine.id)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return (names ?? []).map { LeoAgentTarget(machineID: machine.id, machineName: machine.name, agent: $0) }
    }

    /// Maps what a send threw. A 2xx whose body won't decode counts as a
    /// failure: retrying can duplicate a message, dropping one is worse.
    static func failure(_ error: any Error, target: LeoAgentTarget, text: String) -> LeoAgentSendResult {
        switch error as? LeoDaemonError {
        case .crossOriginRedirect:
            return .unauthorized(target, text: text)
        case .daemon(let code, _, _):
            switch code {
            case "unauthorized", "forbidden": return .unauthorized(target, text: text)
            case "not_found", "agent_not_found": return .agentMissing(target)
            default: return .unreachable(target, text: text)
            }
        default:
            return .unreachable(target, text: text)
        }
    }
}
