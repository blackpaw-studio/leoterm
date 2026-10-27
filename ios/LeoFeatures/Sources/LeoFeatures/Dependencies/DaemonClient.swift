import ComposableArchitecture
import Foundation
import LeoKit

/// A control operation on one agent.
public enum AgentCommand: Equatable, Sendable {
    case interrupt
    case restart
    case setEnvironments([String])
    case start
    case stop
}

/// Talks to paired daemons' web listeners.
@DependencyClient
public struct DaemonClient: Sendable {
    /// Redeems a `leo pair` code at one origin.
    public var pair: @Sendable (_ baseURL: URL, _ code: String, _ deviceName: String, _ cfAccess: LeoCFAccessCredentials?) async throws -> LeoPairingGrant
    public var fetchState: @Sendable (_ connection: DaemonConnection) async throws -> LeoObservedState
    /// One event-stream connection; it ends when the daemon closes it.
    public var events: @Sendable (_ connection: DaemonConnection) -> AsyncThrowingStream<LeoObserveEvent, any Error> = { _ in .finished() }
    public var perform: @Sendable (_ connection: DaemonConnection, _ agent: String, _ command: AgentCommand) async throws -> Void
    public var environmentNames: @Sendable (_ connection: DaemonConnection) async throws -> [String]
    /// `GET /api/v1/appearance/rules` (`agent_appearance`): the rules, to
    /// name one in a source line.
    public var appearanceRules: @Sendable (_ connection: DaemonConnection) async throws -> [LeoAppearanceRule]
    /// `PUT /api/v1/agents/{name}/appearance`: the agent's resolved
    /// appearance after the write, nil when nothing is set.
    public var setAppearance: @Sendable (
        _ connection: DaemonConnection, _ agent: String, _ emoji: LeoAppearanceChange<String>, _ color: LeoAppearanceChange<LeoAppearanceColor>
    ) async throws -> LeoAgentAppearance?
    /// `GET /api/v1/machine`: one load sample (leo >= 0.57, `machine_stats`).
    public var machineStats: @Sendable (_ connection: DaemonConnection) async throws -> LeoMachineStats
    /// `PUT /api/v1/devices/{id}/push`: how the daemon pushes to this device.
    public var setPush: @Sendable (_ connection: DaemonConnection, _ deviceID: String, _ registration: LeoPushRegistration) async throws -> Void
    /// `DELETE /api/v1/devices/{id}/push`.
    public var deletePush: @Sendable (_ connection: DaemonConnection, _ deviceID: String) async throws -> Void
}

/// A stats sample is polled every few seconds, so a slow daemon is skipped
/// quickly rather than held for the default request timeout.
private let machineStatsTimeout: TimeInterval = 3

extension DaemonClient: DependencyKey {
    public static let testValue = DaemonClient()

    public static var liveValue: DaemonClient {
        let session = URLSession(configuration: .default)
        @Sendable func client(_ connection: DaemonConnection, timeout: TimeInterval? = nil) -> LeoWebDaemonClient {
            let transport = LeoHTTPSTransport(endpoint: connection.endpoint, session: session)
            return timeout.map { LeoWebDaemonClient(transport: transport, defaultTimeout: $0) } ?? LeoWebDaemonClient(transport: transport)
        }
        @Sendable func appearance(_ connection: DaemonConnection) -> any LeoAppearanceAPI {
            LeoConfigHTTPClient(prefix: LeoConfigHTTPClient.webPrefix, transport: LeoHTTPSTransport(endpoint: connection.endpoint, session: session))
        }
        return DaemonClient(
            pair: { baseURL, code, deviceName, cfAccess in
                let transport = LeoHTTPSTransport(endpoint: LeoRemoteEndpoint(baseURL: baseURL, token: nil, cfAccess: cfAccess), session: session)
                return try await LeoWebDaemonClient.pair(code: code, deviceName: deviceName, transport: transport)
            },
            fetchState: { try await client($0).fetchState() },
            events: { client($0).events() },
            perform: { connection, agent, command in
                let client = client(connection)
                switch command {
                case .interrupt: try await client.interrupt(agent)
                case .restart: try await client.restart(agent)
                case .setEnvironments(let names): try await client.setEnvironments(agent, names: names)
                case .start: try await client.start(agent)
                case .stop: try await client.stop(agent)
                }
            },
            environmentNames: { try await client($0).environmentNames() },
            appearanceRules: { try await appearance($0).appearanceRules().rules },
            setAppearance: { connection, agent, emoji, color in
                try await appearance(connection).setAgentAppearance(name: agent, emoji: emoji, color: color).appearance
            },
            machineStats: { try await client($0, timeout: machineStatsTimeout).machineStats() },
            setPush: { connection, deviceID, registration in try await client(connection).registerPush(deviceID: deviceID, registration) },
            deletePush: { connection, deviceID in try await client(connection).unregisterPush(deviceID: deviceID) }
        )
    }
}

extension DependencyValues {
    public var daemonClient: DaemonClient {
        get { self[DaemonClient.self] }
        set { self[DaemonClient.self] = newValue }
    }
}
