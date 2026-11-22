import ComposableArchitecture
import Foundation
import LeoKit

/// "Tell an agent" from outside the app (Siri, the Action button, a
/// Shortcut): list the agents on every paired daemon and send one message.
/// A failed send also posts a local notification with Retry, so the text
/// is never dropped. The intents reach it through `AppDependencyManager`;
/// reducers through `@Dependency(\.agentMessaging)`.
public struct AgentMessagingClient: Sendable {
    public var agents: @Sendable () async -> LeoAgentDirectory
    public var send: @Sendable (_ target: LeoAgentTarget, _ text: String) async -> LeoAgentSendResult

    public init(
        agents: @escaping @Sendable () async -> LeoAgentDirectory,
        send: @escaping @Sendable (_ target: LeoAgentTarget, _ text: String) async -> LeoAgentSendResult
    ) {
        self.agents = agents
        self.send = send
    }
}

extension AgentMessagingClient {
    /// Built from the paired daemons and their Keychain credentials. A
    /// daemon without credentials counts as unreachable. `agentNames` and
    /// `transport` are injected so tests stop at the HTTP boundary.
    public static func live(
        pairedDaemons: PairedDaemonsClient,
        secrets: SecretsClient,
        agentNames: @escaping @Sendable (DaemonConnection) async throws -> [String],
        transport: @escaping @Sendable (DaemonConnection) -> any LeoChatTransport,
        notifyFailure: @escaping @Sendable (LeoAgentRetryPayload) async -> Void
    ) -> AgentMessagingClient {
        let sender = LeoAgentMessageSender(
            machines: {
                try pairedDaemons.load().map { daemon in
                    LeoAgentMachine(id: daemon.id, name: daemon.name) {
                        try await agentNames(try secrets.connection(for: daemon))
                    }
                }
            },
            chat: { id in
                guard let daemon = try pairedDaemons.load().first(where: { $0.id == id }) else { throw ChatConnectionError.missingCredentials }
                return LeoChatHTTPClient(transport: transport(try secrets.connection(for: daemon)))
            }
        )
        return AgentMessagingClient(
            agents: { await sender.agents() },
            send: { target, text in
                let result = await sender.send(target, text: text)
                if let payload = result.retryPayload { await notifyFailure(payload) }
                return result
            }
        )
    }
}

extension AgentMessagingClient: DependencyKey {
    public static let testValue = AgentMessagingClient(
        agents: { LeoAgentDirectory(machineCount: 0, targets: []) },
        send: { target, _ in .sent(target) }
    )

    public static var liveValue: AgentMessagingClient {
        @Dependency(\.pairedDaemons) var pairedDaemons
        @Dependency(\.secrets) var secrets
        @Dependency(\.daemonClient) var daemonClient
        @Dependency(\.chatNotifier) var chatNotifier
        let session = URLSession(configuration: .default)
        return live(
            pairedDaemons: pairedDaemons, secrets: secrets,
            agentNames: { connection in try await daemonClient.fetchState(connection).agents.map(\.name) },
            transport: { LeoHTTPSTransport(endpoint: $0.endpoint, session: session) },
            notifyFailure: { await chatNotifier.sendFailed($0) }
        )
    }
}

extension DependencyValues {
    public var agentMessaging: AgentMessagingClient {
        get { self[AgentMessagingClient.self] }
        set { self[AgentMessagingClient.self] = newValue }
    }
}
